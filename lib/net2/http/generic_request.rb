require "net2/http/header"
require "rbconfig"

module Net2
  class HTTP
    # HTTPGenericRequest is the parent of the HTTPRequest class.
    # Do not use this directly; use a subclass of HTTPRequest.
    #
    # Mixes in the HTTPHeader module to provide easier access to HTTP headers.
    #
    class GenericRequest

      include Header

      config = Config::CONFIG
      engine = defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby"

      HTTP_ACCEPT_ENCODING = "gzip;q=1.0,deflate;q=0.6,identity;q=0.3" if HAVE_ZLIB
      HTTP_ACCEPT          = "*/*"
      HTTP_USER_AGENT      = "Ruby/#{RUBY_VERSION} (#{engine}) #{RUBY_DESCRIPTION}"

      def initialize(m, req_body_allowed, resp_body_allowed, path, headers = nil)
        raise ArgumentError, "no HTTP request path given" unless path
        raise ArgumentError, "HTTP request path is empty" if path.empty?

        @method = m
        @path = path

        @request_has_body = req_body_allowed
        @response_has_body = resp_body_allowed

        self.headers = headers

        self['Accept-Encoding'] ||= HTTP_ACCEPT_ENCODING if HTTP_ACCEPT_ENCODING
        self['Accept']          ||= HTTP_ACCEPT
        self['User-Agent']      ||= HTTP_USER_AGENT

        @body = @body_stream = @body_data = nil
      end

      attr_reader :method
      attr_reader :path

      def inspect
        "\#<#{self.class} #{@method}>"
      end

      def request_body_permitted?
        @request_has_body
      end

      def response_body_permitted?
        @response_has_body
      end

      def body_exist?
        warn "Net::HTTPRequest#body_exist? is obsolete; use response_body_permitted?" if $VERBOSE
        response_body_permitted?
      end

      attr_reader :body

      def body=(str)
        return self.body_stream = str if str.respond_to?(:read)

        @body = str
        @body_stream = nil
        @body_data = nil
        str
      end

      attr_reader :body_stream

      def body_stream=(input)
        @body = nil
        @body_stream = input
        @body_data = nil
        input
      end

      def set_body_internal(str)   #:nodoc: internal use only
        raise ArgumentError, "both of body argument and HTTPRequest#body set" if str and (@body or @body_stream)
        self.body = str if str
      end

      #
      # write
      #

      def exec(sock, ver, path)   #:nodoc: internal use only
        if @body
          request_with_body sock, ver, path
        elsif @body_stream
          request_with_stream sock, ver, path
        elsif @body_data
          request_with_data sock, ver, path
        else
          write_header sock, ver, path
        end
      end

      private

      def supply_default_content_type
        return if content_type
        warn 'net/http: warning: Content-Type did not set; using application/x-www-form-urlencoded' if $VERBOSE
        set_content_type 'application/x-www-form-urlencoded'
      end

      def write_header(sock, ver, path)
        buf = "#{@method} #{path} HTTP/#{ver}\r\n"
        each_capitalized do |k,v|
          buf << "#{k}: #{v}\r\n"
        end
        buf << "\r\n"
        sock.write buf
      end

      def request_with_body(sock, ver, path, body = @body)
        self.content_length = body.bytesize
        delete 'Transfer-Encoding'

        supply_default_content_type
        write_header sock, ver, path

        sock.write body
      end

      def request_with_stream(sock, ver, path, f = @body_stream)
        unless content_length or chunked?
          raise ArgumentError,
              "Content-Length not given and Transfer-Encoding is not `chunked'"
        end

        supply_default_content_type
        write_header sock, ver, path

        if chunked?
          while s = f.read(1024)
            sock.write "#{s.length}\r\n#{s}\r\n"
          end
          sock.write "0\r\n\r\n"
        else
          while s = f.read(1024)
            sock.write s
          end
        end
      end

      def request_with_data(sock, ver, path, params = @body_data)
        # normalize URL encoded requests to normal requests with body
        if /\Amultipart\/form-data\z/i !~ self.content_type
          self.content_type = 'application/x-www-form-urlencoded'
          @body = URI.encode_www_form(params)
          return exec(sock, ver, path)
        end

        opt = @form_option.dup
        opt[:boundary] ||= SecureRandom.urlsafe_base64(40)
        self.set_content_type(self.content_type, :boundary => opt[:boundary])
        if chunked?
          write_header sock, ver, path
          encode_multipart_form_data(sock, params, opt)
        else
          require 'tempfile'
          file = Tempfile.new('multipart')
          file.binmode
          encode_multipart_form_data(file, params, opt)
          file.rewind
          self.content_length = file.size
          write_header sock, ver, path
          IO.copy_stream(file, sock)
        end
      end

      def encode_multipart_form_data(out, params, opt)
        charset = opt[:charset]
        boundary = opt[:boundary]
        boundary ||= SecureRandom.urlsafe_base64(40)
        chunked_p = chunked?

        buf = ''
        params.each do |key, value, h|
          h ||= {}

          key = quote_string(key, charset)
          filename =
            h.key?(:filename) ? h[:filename] :
            value.respond_to?(:to_path) ? File.basename(value.to_path) :
            nil

          buf << "--#{boundary}\r\n"
          if filename
            filename = quote_string(filename, charset)
            type = h[:content_type] || 'application/octet-stream'
            buf << "Content-Disposition: form-data; " \
              "name=\"#{key}\"; filename=\"#{filename}\"\r\n" \
              "Content-Type: #{type}\r\n\r\n"
            if !out.respond_to?(:write) || !value.respond_to?(:read)
              # if +out+ is not an IO or +value+ is not an IO
              buf << (value.respond_to?(:read) ? value.read : value)
            elsif value.respond_to?(:size) && chunked_p
              # if +out+ is an IO and +value+ is a File, use IO.copy_stream
              flush_buffer(out, buf, chunked_p)
              out << "%x\r\n" % value.size if chunked_p
              IO.copy_stream(value, out)
              out << "\r\n" if chunked_p
            else
              # +out+ is an IO, and +value+ is not a File but an IO
              flush_buffer(out, buf, chunked_p)
              1 while flush_buffer(out, value.read(4096), chunked_p)
            end
          else
            # non-file field:
            #   HTML5 says, "The parts of the generated multipart/form-data
            #   resource that correspond to non-file fields must not have a
            #   Content-Type header specified."
            buf << "Content-Disposition: form-data; name=\"#{key}\"\r\n\r\n"
            buf << (value.respond_to?(:read) ? value.read : value)
          end
          buf << "\r\n"
        end
        buf << "--#{boundary}--\r\n"
        flush_buffer(out, buf, chunked_p)
        out << "0\r\n\r\n" if chunked_p
      end

      def quote_string(str, charset)
        str = str.encode(charset, :fallback => lambda {|c| '&#%d;'%c.encode("UTF-8").ord}) if charset
        str = str.gsub(/[\\"]/, '\\\\\&')
      end

      def flush_buffer(out, buf, chunked_p)
        return unless buf
        out << "%x\r\n"%buf.bytesize if chunked_p
        out << buf
        out << "\r\n" if chunked_p
        buf.gsub!(/\A.*\z/m, '')
      end

    end
  end

  HTTPGenericRequest = HTTP::GenericRequest
end
