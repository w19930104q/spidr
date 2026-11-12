# frozen_string_literal: true

require 'time'

module Spidr
  #
  # Represents an HTTP Cookie stored within the {CookieJar}. Each cookie
  # remembers the scheme, host, port and path of the response that set it,
  # along with the `Secure` flag and expiry time, so that it is only sent
  # back to URLs it actually belongs to.
  #
  # @since 0.7.3
  #
  class Cookie

    # The name of the cookie.
    #
    # @return [String]
    attr_reader :name

    # The value of the cookie.
    #
    # @return [String]
    attr_accessor :value

    # The scheme of the response that set the cookie.
    #
    # @return [String, nil]
    attr_reader :scheme

    # The host (or domain) the cookie is bound to.
    #
    # @return [String]
    attr_reader :host

    # The port of the response that set the cookie.
    #
    # @return [Integer, nil]
    attr_reader :port

    # The path the cookie is scoped to.
    #
    # @return [String]
    attr_reader :path

    # The time at which the cookie expires.
    #
    # @return [Time, nil]
    attr_reader :expires

    #
    # Creates a new cookie.
    #
    # @param [String] name
    #   The name of the cookie.
    #
    # @param [String] value
    #   The value of the cookie.
    #
    # @param [String, nil] scheme
    #   The scheme of the response that set the cookie.
    #
    # @param [String] host
    #   The host (or domain) the cookie is bound to.
    #
    # @param [Integer, nil] port
    #   The port of the response that set the cookie. A `nil` port matches
    #   any port.
    #
    # @param [String] path
    #   The path the cookie is scoped to.
    #
    # @param [Boolean] secure
    #   Specifies whether the cookie may only be sent over HTTPS.
    #
    # @param [Time, nil] expires
    #   The time at which the cookie expires. A `nil` expiry indicates a
    #   session cookie.
    #
    def initialize(name: , value: , scheme: nil, host: , port: nil, path: '/',
                   secure: false, expires: nil)
      @name    = name
      @value   = value
      @scheme  = scheme
      @host    = host
      @port    = port
      @path    = (path.nil? || path.empty?) ? '/' : path
      @secure  = secure
      @expires = expires
    end

    #
    # Parses a `Set-Cookie` header value, scoping the cookie to the URL of
    # the response that set it.
    #
    # @param [String] set_cookie
    #   The raw `Set-Cookie` header value.
    #
    # @param [URI::HTTP] url
    #   The URL of the response that set the cookie.
    #
    # @return [Cookie, nil]
    #   The parsed cookie, or `nil` if the header value was malformed.
    #
    def self.parse(set_cookie,url)
      fields = set_cookie.split(';')
      first  = fields.shift

      return nil if first.nil?

      name, value = first.strip.split('=',2)

      return nil if (name.nil? || name.empty?)

      # default attributes taken from the response URL
      scheme  = url.scheme
      host    = url.host
      port    = url.port
      path    = default_path(url)
      secure  = false
      expires = nil
      max_age = nil

      fields.each do |field|
        attr_name, attr_value = field.strip.split('=',2)

        next if (attr_name.nil? || attr_name.empty?)

        case attr_name.downcase
        when 'domain'
          if attr_value
            domain = attr_value.sub(/\A\.+/,'')

            # only honor the Domain attribute if the response host
            # actually resides within the domain
            if (url.host == domain || url.host.end_with?(".#{domain}"))
              host = domain
            end
          end
        when 'path'
          path = attr_value if (attr_value && !attr_value.empty?)
        when 'secure'
          secure = true
        when 'expires'
          if attr_value
            begin
              expires = Time.httpdate(attr_value)
            rescue ArgumentError
            end
          end
        when 'max-age'
          if attr_value
            begin
              max_age = Integer(attr_value,10)
            rescue ArgumentError
            end
          end
        end
      end

      # Max-Age takes precedence over Expires
      expires = (Time.now + max_age) if max_age

      return new(
        name:    name,
        value:   (value || ''),
        scheme:  scheme,
        host:    host,
        port:    port,
        path:    path,
        secure:  secure,
        expires: expires
      )
    end

    #
    # The default cookie path for a response URL, as described in
    # RFC 6265, section 5.1.4.
    #
    # @param [URI::HTTP] url
    #   The URL of the response that set the cookie.
    #
    # @return [String]
    #   The default cookie path.
    #
    def self.default_path(url)
      path = url.path

      return '/' if (path.nil? || path.empty? || !path.start_with?('/'))
      return '/' if (path.count('/') <= 1)

      return path[0...path.rindex('/')]
    end

    #
    # Determines whether the cookie may only be sent over HTTPS.
    #
    # @return [Boolean]
    #
    def secure?
      @secure == true
    end

    #
    # Determines whether the cookie has expired.
    #
    # @param [Time] time
    #   The time to compare against the expiry time.
    #
    # @return [Boolean]
    #
    def expired?(time=Time.now)
      !@expires.nil? && @expires <= time
    end

    #
    # Determines whether the cookie should be sent to the given URL.
    #
    # @param [URI::HTTP] url
    #   The URL about to be requested.
    #
    # @return [Boolean]
    #
    def matches?(url)
      return false if expired?
      return false if (secure? && url.scheme != 'https')
      return false if (@port && url.port != @port)
      return false unless (url.host == @host ||
                           url.host.end_with?(".#{@host}"))

      return matches_path?(url.path)
    end

    #
    # Determines whether the cookie's path scopes it to the given
    # request path, as described in RFC 6265, section 5.1.4.
    #
    # @param [String] request_path
    #   The request path.
    #
    # @return [Boolean]
    #
    def matches_path?(request_path)
      request_path = '/' if (request_path.nil? || request_path.empty?)

      return true if (request_path == @path)

      request_path.start_with?(@path) &&
        (@path.end_with?('/') || request_path[@path.length] == '/')
    end

    #
    # The cookie as a `name=value` pair, suitable for the `Cookie` header.
    #
    # @return [String]
    #
    def to_s
      "#{@name}=#{@value}"
    end

    #
    # Inspects the cookie.
    #
    # @return [String]
    #
    def inspect
      "#<#{self.class}: #{self} host=#{@host} port=#{@port} path=#{@path}>"
    end

  end
end
