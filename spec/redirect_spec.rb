require 'spec_helper'

require 'spidr/agent'

require 'webrick'
require 'socket'
require 'base64'

#
# Regression tests for redirect handling, run against real HTTP servers
# listening on multiple local host-names and ports.
#
describe "redirects over local HTTP" do
  #
  # A minimal WEBrick based HTTP server bound to a local host-name.
  #
  class TestHTTPServer
    attr_reader :host, :port, :requests

    def initialize(host: '127.0.0.1')
      @host     = host
      @port     = self.class.free_port
      @routes   = {}
      @requests = []
      @mutex    = Mutex.new

      @server = WEBrick::HTTPServer.new(
        BindAddress: '127.0.0.1',
        Port:        @port,
        Logger:      WEBrick::Log.new(File::NULL),
        AccessLog:   []
      )
      @server.mount_proc('/') do |request,response|
        handle(request,response)
      end

      @thread = Thread.new { @server.start }
    end

    def self.free_port
      server = TCPServer.new('127.0.0.1',0)
      server.addr[1]
    ensure
      server.close
    end

    def route(path,&block)
      @routes[path] = block
    end

    def url(path='/')
      URI("http://#{@host}:#{@port}#{path}")
    end

    def requests_for(path)
      @mutex.synchronize { @requests.select { |request| request.path == path } }
    end

    def shutdown
      @server.shutdown
      @thread.join(5)
    end

    protected

    def handle(request,response)
      @mutex.synchronize { @requests << request }

      if (handler = @routes[request.path])
        handler.call(request,response)
      else
        response.status = 404
        response.body   = 'not found'
      end
    end
  end

  # two separate origins: different host-names and different ports
  let!(:server_a) { TestHTTPServer.new(host: '127.0.0.1') }
  let!(:server_b) { TestHTTPServer.new(host: 'localhost') }

  # these tests make real HTTP requests to local WEBrick servers, so
  # temporarily allow localhost connections when WebMock is loaded
  around do |example|
    if defined?(WebMock)
      begin
        WebMock.allow_net_connect!(allow_localhost: true)
        example.run
      ensure
        WebMock.disable_net_connect!
      end
    else
      example.run
    end
  end

  after do
    server_a.shutdown
    server_b.shutdown
  end

  def html_response(response,html)
    response['Content-Type'] = 'text/html'
    response.body = html
  end

  describe "cross-site redirects" do
    before do
      server_a.route('/start') do |request,response|
        response.status = 302
        response['Location']   = server_b.url('/landing').to_s
        response['Set-Cookie'] = 'secret=hunter2'
      end

      server_b.route('/landing') do |request,response|
        html_response(response,%{<html><body>landed</body></html>})
      end
    end

    let(:agent) do
      Spidr::Agent.new do |agent|
        agent.authorized.add(server_a.url('/'),'user','password')
      end
    end

    it "should identify the page by the final response URL" do
      pages = []
      agent.every_page { |page| pages << page }

      agent.start_at(server_a.url('/start'))

      expect(pages.length).to eq(1)
      expect(pages.first.url).to eq(server_b.url('/landing'))
    end

    it "should record the landing URL in the history" do
      agent.start_at(server_a.url('/start'))

      expect(agent.history).to include(server_b.url('/landing'))
      expect(agent.history).to include(server_a.url('/start'))
    end

    it "should bind the response cookies to the origin host" do
      agent.start_at(server_a.url('/start'))

      expect(agent.cookies[server_a.host]).to eq({'secret' => 'hunter2'})
      expect(agent.cookies[server_b.host]).to be_empty
    end

    it "should not send the origin's cookies to the redirect target" do
      agent.start_at(server_a.url('/start'))

      request = server_b.requests_for('/landing').last

      expect(request['Cookie']).to be_nil
    end

    it "should not send the origin's Basic-Auth credentials to the redirect target" do
      agent.start_at(server_a.url('/start'))

      # the origin did receive its own credentials
      origin_request = server_a.requests_for('/start').last
      expect(origin_request['Authorization']).to include(
        Base64.strict_encode64('user:password')
      )

      # but the other host must not
      target_request = server_b.requests_for('/landing').last
      expect(target_request['Authorization']).to be_nil
    end
  end

  describe "same-site redirects" do
    before do
      server_a.route('/start') do |request,response|
        response.status = 302
        # a relative Location, resolved against the origin URL
        response['Location']   = '/landing'
        response['Set-Cookie'] = 'session=abc123'
      end

      server_a.route('/landing') do |request,response|
        html_response(response,%{<html><body>landed</body></html>})
      end
    end

    let(:agent) do
      Spidr::Agent.new do |agent|
        agent.authorized.add(server_a.url('/'),'user','password')
      end
    end

    it "should resolve relative Location headers against the current URL" do
      page = agent.get_page(server_a.url('/start'))

      expect(page.url).to eq(server_a.url('/landing'))
    end

    it "should preserve cookies across the redirect" do
      agent.start_at(server_a.url('/start'))

      request = server_a.requests_for('/landing').last

      expect(request['Cookie']).to include('session=abc123')
    end

    it "should preserve Basic-Auth credentials across the redirect" do
      agent.start_at(server_a.url('/start'))

      request = server_a.requests_for('/landing').last

      expect(request['Authorization']).to include(
        Base64.strict_encode64('user:password')
      )
    end
  end

  describe "relative links" do
    before do
      server_a.route('/old/start') do |request,response|
        response.status = 302
        response['Location'] = server_b.url('/new/dir/page').to_s
      end

      server_b.route('/new/dir/page') do |request,response|
        html_response(response,<<~HTML)
          <html>
            <body>
              <a href="other">other</a>
              <a href="../up">up</a>
            </body>
          </html>
        HTML
      end

      server_b.route('/new/dir/other') do |request,response|
        html_response(response,%{<html><body>other</body></html>})
      end

      server_b.route('/new/up') do |request,response|
        html_response(response,%{<html><body>up</body></html>})
      end
    end

    let(:agent) { Spidr::Agent.new }

    it "should expand relative links against the final response URL" do
      pages = []
      agent.every_page { |page| pages << page }
      agent.start_at(server_a.url('/old/start'))

      landing = pages.find { |page| page.url == server_b.url('/new/dir/page') }

      expect(landing).to_not be_nil
      expect(landing.urls).to include(server_b.url('/new/dir/other'))
      expect(landing.urls).to include(server_b.url('/new/up'))
    end

    it "should visit the links resolved against the final URL" do
      agent.start_at(server_a.url('/old/start'))

      expect(agent.history).to include(server_b.url('/new/dir/other'))
      expect(agent.history).to include(server_b.url('/new/up'))
      expect(agent.failures).to be_empty
    end
  end

  describe "cookie attributes" do
    before do
      server_a.route('/set') do |request,response|
        html_response(response,<<~HTML)
          <html>
            <body>
              <a href="/sub/page">sub</a>
              <a href="/other">other</a>
            </body>
          </html>
        HTML

        path_cookie = WEBrick::Cookie.new('path_cookie','1')
        path_cookie.path = '/sub'

        secure_cookie = WEBrick::Cookie.new('secure_cookie','1')
        secure_cookie.secure = true

        expired_cookie = WEBrick::Cookie.new('expired_cookie','1')
        expired_cookie.max_age = 0

        live_cookie = WEBrick::Cookie.new('live_cookie','1')
        live_cookie.max_age = 3600

        response.cookies.concat([
          path_cookie, secure_cookie, expired_cookie, live_cookie
        ])
      end

      server_a.route('/sub/page') do |request,response|
        html_response(response,%{<html><body>sub</body></html>})
      end

      server_a.route('/other') do |request,response|
        html_response(response,%{<html><body>other</body></html>})
      end
    end

    let(:agent) { Spidr::Agent.new }

    it "should only send cookies whose path matches the request path" do
      agent.start_at(server_a.url('/set'))

      sub_request = server_a.requests_for('/sub/page').last
      expect(sub_request['Cookie']).to include('path_cookie=1')

      other_request = server_a.requests_for('/other').last
      expect(other_request['Cookie']).to_not include('path_cookie=1')
    end

    it "should not send secure cookies over HTTP" do
      agent.start_at(server_a.url('/set'))

      request = server_a.requests_for('/sub/page').last

      expect(request['Cookie']).to_not include('secure_cookie')
    end

    it "should not send expired cookies" do
      agent.start_at(server_a.url('/set'))

      request = server_a.requests_for('/sub/page').last

      expect(request['Cookie']).to_not include('expired_cookie')
    end

    it "should send unexpired cookies" do
      agent.start_at(server_a.url('/set'))

      request = server_a.requests_for('/sub/page').last

      expect(request['Cookie']).to include('live_cookie=1')
    end

    it "should not send cookies to a different port on the same host" do
      # server on the same host-name, but a different port
      other_port_server = TestHTTPServer.new(host: server_a.host)

      begin
        server_a.route('/jump') do |request,response|
          response.status = 302
          response['Location']   = other_port_server.url('/landing').to_s
          response['Set-Cookie'] = 'secret=hunter2'
        end

        other_port_server.route('/landing') do |request,response|
          html_response(response,%{<html><body>landed</body></html>})
        end

        agent.start_at(server_a.url('/jump'))

        request = other_port_server.requests_for('/landing').last
        expect(request['Cookie']).to be_nil
      ensure
        other_port_server.shutdown
      end
    end
  end

  describe "redirect loops" do
    before do
      server_a.route('/loop1') do |request,response|
        response.status = 302
        response['Location'] = server_b.url('/loop2').to_s
      end

      server_b.route('/loop2') do |request,response|
        response.status = 302
        response['Location'] = server_a.url('/loop1').to_s
      end
    end

    let(:agent) { Spidr::Agent.new }

    it "should terminate and not count the loop repeatedly" do
      pages = []
      agent.every_page { |page| pages << page }

      agent.start_at(server_a.url('/loop1'))

      # the loop was only traversed once
      expect(server_a.requests_for('/loop1').length).to eq(1)
      expect(server_b.requests_for('/loop2').length).to eq(1)

      # a single page, identified by the last response in the chain
      expect(pages.length).to eq(1)
      expect(pages.first.url).to eq(server_b.url('/loop2'))

      # each URL in the loop is counted once
      expect(agent.history).to eq(Set[
        server_a.url('/loop1'),
        server_b.url('/loop2')
      ])
      expect(agent.failures).to be_empty
    end
  end

  describe "redirect targets that are already queued" do
    before do
      server_a.route('/') do |request,response|
        html_response(response,<<~HTML)
          <html>
            <body>
              <a href="/r1">redirect</a>
              <a href="/final">direct</a>
            </body>
          </html>
        HTML
      end

      server_a.route('/r1') do |request,response|
        response.status = 302
        response['Location'] = '/final'
      end

      server_a.route('/final') do |request,response|
        html_response(response,%{<html><body>final</body></html>})
      end
    end

    it "should not visit the landing URL twice" do
      agent   = Spidr::Agent.new
      visited = []

      agent.every_page { |page| visited << page.url }
      agent.start_at(server_a.url('/'))

      expect(server_a.requests_for('/final').length).to eq(1)
      expect(visited.count(server_a.url('/final'))).to eq(1)
      expect(agent.history).to eq(Set[
        server_a.url('/'),
        server_a.url('/r1'),
        server_a.url('/final')
      ])
    end
  end

  describe "self redirects" do    before do
      server_a.route('/self') do |request,response|
        response.status = 302
        response['Location'] = '/self'
      end
    end

    it "should terminate immediately" do
      agent = Spidr::Agent.new

      pages = []
      agent.every_page { |page| pages << page }
      agent.start_at(server_a.url('/self'))

      expect(server_a.requests_for('/self').length).to eq(1)
      expect(pages.length).to eq(1)
      expect(agent.history).to eq(Set[server_a.url('/self')])
    end
  end

  describe "failing redirect targets" do
    let(:dead_url) { URI("http://127.0.0.1:#{TestHTTPServer.free_port}/gone") }

    before do
      server_a.route('/start') do |request,response|
        response.status = 302
        response['Location'] = dead_url.to_s
      end
    end

    it "should record the failed landing URL in the failures" do
      agent = Spidr::Agent.new
      agent.start_at(server_a.url('/start'))

      expect(agent.failures).to include(dead_url)
      expect(agent.failures).to_not include(server_a.url('/start'))
      expect(agent.history).to be_empty
    end
  end

  describe "pause and continue" do
    before do
      server_a.route('/') do |request,response|
        html_response(response,<<~HTML)
          <html>
            <body>
              <a href="/r1">redirect</a>
              <a href="/plain">plain</a>
            </body>
          </html>
        HTML
      end

      server_a.route('/r1') do |request,response|
        response.status = 302
        response['Location'] = '/final'
      end

      server_a.route('/final') do |request,response|
        html_response(response,%{<html><body>final</body></html>})
      end

      server_a.route('/plain') do |request,response|
        html_response(response,%{<html><body>plain</body></html>})
      end
    end

    it "should see the same landing URLs when pausing and continuing" do
      agent   = Spidr::Agent.new
      visited = []

      agent.every_page do |page|
        visited << page.url

        agent.pause! if page.url.path == '/final'
      end

      agent.start_at(server_a.url('/'))

      # paused on the landing page of the redirect
      expect(agent).to be_paused
      expect(visited).to eq([server_a.url('/'), server_a.url('/final')])
      expect(agent.history).to include(server_a.url('/final'))

      # the remaining URL is still queued
      expect(agent.queue).to eq([server_a.url('/plain')])

      agent.continue!

      # every page was seen exactly once, at its final URL
      expect(visited).to eq([
        server_a.url('/'),
        server_a.url('/final'),
        server_a.url('/plain')
      ])
      expect(agent.history).to eq(Set[
        server_a.url('/'),
        server_a.url('/r1'),
        server_a.url('/final'),
        server_a.url('/plain')
      ])
      expect(agent.failures).to be_empty
    end
  end
end
