# frozen_string_literal: true

require_relative 'page'
require_relative 'cookie'

require 'set'

module Spidr
  #
  # Stores HTTP Cookies organized by host-name. Each cookie is stored
  # along with the scheme, host, port, path, secure flag and expiry of
  # the response that set it.
  #
  class CookieJar

    include Enumerable

    #
    # Creates a new Cookie Jar object.
    #
    # @since 0.2.2
    #
    def initialize
      @params = {}

      @dirty   = Set[]
      @cookies = {}
    end

    #
    # Enumerates over the host-name and cookie value pairs in the
    # cookie jar.
    #
    # @yield [host, cookie]
    #   If a block is given, it will be passed each host-name and cookie
    #   value pair.
    #
    # @yieldparam [String] host
    #   The host-name that the cookie is bound to.
    #
    # @yieldparam [String] cookie
    #   The cookie value.
    #
    # @since 0.2.2
    #
    def each(&block)
      return enum_for(__method__) unless block_given?

      @params.each do |host,cookies|
        values = {}

        cookies.each do |name,cookie|
          values[name] = cookie.value
        end

        block.call(host,values)
      end
    end

    #
    # Return all relevant cookies in a single string for the
    # named host or domain (in browser request format).
    #
    # @param [String] host
    #   Host or domain name for cookies.
    #
    # @return [Hash{String => String}]
    #   The cookie values for the host.
    #
    # @since 0.2.2
    #
    def [](host)
      values = {}

      (@params[host] || {}).each do |name,cookie|
        values[name] = cookie.value
      end

      return values
    end

    #
    # Add a cookie to the jar for a particular domain.
    #
    # @param [String] host
    #   Host or domain name to associate with the cookie.
    #
    # @param [Hash{String => String}] cookies
    #   Cookie params.
    #
    # @since 0.2.2
    #
    def []=(host,cookies)
      collected = (@params[host] ||= {})

      cookies.each do |name,value|
        if (cookie = collected[name])
          if cookie.value != value
            cookie.value = value
            @dirty << host
          end
        else
          collected[name] = Cookie.new(name: name, value: value, host: host)
          @dirty << host
        end
      end

      return cookies
    end

    #
    # Retrieve cookies for a domain from a page response header.
    #
    # @param [Page] page
    #   The response page from which to extract cookie data.
    #
    # @return [Boolean]
    #   Specifies whether cookies were added from the page.
    #
    # @since 0.2.2
    #
    def from_page(page)
      from_response(page.url,page.response)
    end

    #
    # Stores the cookies from a response, binding each cookie to the
    # scheme, host, port and path of the URL that the response came from.
    #
    # @param [URI::HTTP, String] url
    #   The URL of the response.
    #
    # @param [Net::HTTPResponse] response
    #   The response containing `Set-Cookie` headers.
    #
    # @return [Boolean]
    #   Specifies whether cookies were added from the response.
    #
    # @since 0.7.3
    #
    def from_response(url,response)
      url = URI(url)

      set_cookies = (response.get_fields('Set-Cookie') || [])

      return false if set_cookies.empty?

      set_cookies.each do |value|
        if (cookie = Cookie.parse(value,url))
          store(cookie)
        end
      end

      return true
    end

    #
    # Stores a cookie in the jar. Storing an already expired cookie
    # removes any existing cookie with the same name.
    #
    # @param [Cookie] cookie
    #   The cookie to store.
    #
    # @return [Cookie]
    #   The stored cookie.
    #
    # @since 0.7.3
    #
    def store(cookie)
      collected = (@params[cookie.host] ||= {})

      if cookie.expired?
        # an already expired cookie deletes the existing cookie
        if collected.delete(cookie.name)
          @dirty << cookie.host
        end
      else
        collected[cookie.name] = cookie
        @dirty << cookie.host
      end

      return cookie
    end

    #
    # Returns the pre-encoded Cookie for a given host.
    #
    # @param [String] host
    #   The name of the host.
    #
    # @return [String]
    #   The encoded Cookie.
    #
    # @since 0.2.2
    #
    def for_host(host)
      if @dirty.include?(host)
        values = []

        cookies_for_host(host).each do |name,value|
          values << "#{name}=#{value}"
        end

        @cookies[host] = values.join('; ')
        @dirty.delete(host)
      end

      return @cookies[host]
    end

    #
    # Returns the pre-encoded Cookie header value for a given URL,
    # containing only the cookies whose host, port, path, secure flag
    # and expiry allow them to be sent to the URL.
    #
    # @param [URI::HTTP, String] url
    #   The URL about to be requested.
    #
    # @return [String, nil]
    #   The encoded Cookie, or `nil` if no cookies match the URL.
    #
    # @since 0.7.3
    #
    def for_url(url)
      url = URI(url)

      values = []
      names  = Set[]

      each_host_and_parent(url.host) do |host|
        if (cookies = @params[host])
          cookies.each_value do |cookie|
            # cookies from a more specific host take precedence
            next if names.include?(cookie.name)

            if cookie.matches?(url)
              values << cookie.to_s
              names  << cookie.name
            end
          end
        end
      end

      return nil if values.empty?

      return values.join('; ')
    end

    #
    # Returns raw cookie value pairs for a given host. Includes cookies set on
    # parent domain(s).
    #
    # @param [String] host
    #   The name of the host.
    #
    # @return [Hash{String => String}]
    #   Cookie params.
    #
    # @since 0.2.7
    #
    def cookies_for_host(host)
      host_cookies = {}

      each_host_and_parent(host) do |current_host|
        if (parent_cookies = @params[current_host])
          parent_cookies.each do |name,cookie|
            next if cookie.expired?

            # copy in the parent cookies, only if they haven't been
            # overridden yet.
            unless host_cookies.has_key?(name)
              host_cookies[name] = cookie.value
            end
          end
        end
      end

      return host_cookies
    end

    #
    # Clear out the jar, removing all stored cookies.
    #
    # @since 0.2.2
    #
    def clear!
      @params.clear

      @dirty.clear
      @cookies.clear
      return self
    end

    #
    # Size of the current cookie jar store.
    #
    # @since 0.2.2
    #
    def size
      @params.size
    end

    #
    # Inspects the cookie jar.
    #
    # @return [String]
    #   The inspected version of the cookie jar.
    #
    def inspect
      "#<#{self.class}: #{@params.inspect}>"
    end

    protected

    #
    # Yields the given host-name, then each of its parent domains.
    #
    # @param [String] host
    #   The host-name.
    #
    # @yield [domain]
    #   Each host-name or parent domain.
    #
    # @yieldparam [String] domain
    #   A host-name or parent domain.
    #
    def each_host_and_parent(host)
      yield host

      sub_domains = host.split('.')

      while sub_domains.length > 2
        sub_domains.shift

        yield sub_domains.join('.')
      end
    end

  end
end
