require 'spec_helper'

require 'spidr/cookie'

describe Cookie do
  let(:url) { URI('http://example.com/dir/page') }

  describe ".parse" do
    it "should parse the name and value" do
      cookie = described_class.parse('session=abc123',url)

      expect(cookie.name).to  eq('session')
      expect(cookie.value).to eq('abc123')
    end

    it "should handle values containing '='" do
      cookie = described_class.parse('token=abc=def=',url)

      expect(cookie.name).to  eq('token')
      expect(cookie.value).to eq('abc=def=')
    end

    it "should ignore empty attribute fields" do
      cookie = described_class.parse('session=abc;; Secure; ',url)

      expect(cookie.name).to eq('session')
      expect(cookie).to be_secure
    end

    it "should return nil for malformed cookies" do
      expect(described_class.parse('',url)).to be_nil
      expect(described_class.parse('; Path=/',url)).to be_nil
    end

    it "should bind the cookie to the scheme, host and port of the URL" do
      cookie = described_class.parse('session=abc',URI('http://example.com:8080/dir/page'))

      expect(cookie.scheme).to eq('http')
      expect(cookie.host).to   eq('example.com')
      expect(cookie.port).to   eq(8080)
    end

    it "should default the path to the directory of the URL" do
      cookie = described_class.parse('session=abc',url)

      expect(cookie.path).to eq('/dir')
    end

    it "should default the path to '/' for top-level URLs" do
      cookie = described_class.parse('session=abc',URI('http://example.com/top'))

      expect(cookie.path).to eq('/')
    end

    it "should default the path to '/' for the root URL" do
      cookie = described_class.parse('session=abc',URI('http://example.com/'))

      expect(cookie.path).to eq('/')
    end

    it "should parse the Path attribute" do
      cookie = described_class.parse('session=abc; Path=/sub',url)

      expect(cookie.path).to eq('/sub')
    end

    it "should parse the Secure attribute" do
      cookie = described_class.parse('session=abc; Secure',url)

      expect(cookie).to be_secure
    end

    it "should not be secure by default" do
      cookie = described_class.parse('session=abc',url)

      expect(cookie).to_not be_secure
    end

    it "should parse the Expires attribute" do
      cookie = described_class.parse(
        'session=abc; Expires=Wed, 21 Oct 2030 07:28:00 GMT',url
      )

      expect(cookie.expires).to eq(Time.httpdate('Wed, 21 Oct 2030 07:28:00 GMT'))
    end

    it "should ignore unparseable Expires attributes" do
      cookie = described_class.parse('session=abc; Expires=not-a-date',url)

      expect(cookie.expires).to be_nil
    end

    it "should parse the Max-Age attribute" do
      cookie = described_class.parse('session=abc; Max-Age=3600',url)

      expect(cookie.expires).to be_within(2).of(Time.now + 3600)
    end

    it "should prefer Max-Age over Expires" do
      cookie = described_class.parse(
        'session=abc; Expires=Wed, 21 Oct 2030 07:28:00 GMT; Max-Age=60',url
      )

      expect(cookie.expires).to be_within(2).of(Time.now + 60)
    end

    it "should parse the Domain attribute for the same host" do
      cookie = described_class.parse('session=abc; Domain=example.com',url)

      expect(cookie.host).to eq('example.com')
    end

    it "should parse the Domain attribute for a parent domain" do
      cookie = described_class.parse(
        'session=abc; Domain=example.com',
        URI('http://www.example.com/')
      )

      expect(cookie.host).to eq('example.com')
    end

    it "should ignore the Domain attribute for foreign domains" do
      cookie = described_class.parse('session=abc; Domain=other.com',url)

      expect(cookie.host).to eq('example.com')
    end

    it "should ignore the Domain attribute for sub-domains of the host" do
      cookie = described_class.parse('session=abc; Domain=www.example.com',url)

      expect(cookie.host).to eq('example.com')
    end
  end

  describe "#expired?" do
    it "should be false for session cookies" do
      cookie = described_class.new(name: 'a', value: '1', host: 'example.com')

      expect(cookie).to_not be_expired
    end

    it "should be true when the expiry time has passed" do
      cookie = described_class.new(
        name: 'a', value: '1', host: 'example.com',
        expires: Time.now - 60
      )

      expect(cookie).to be_expired
    end

    it "should be false when the expiry time is in the future" do
      cookie = described_class.new(
        name: 'a', value: '1', host: 'example.com',
        expires: Time.now + 60
      )

      expect(cookie).to_not be_expired
    end
  end

  describe "#matches?" do
    let(:cookie) do
      described_class.new(
        name: 'a', value: '1',
        scheme: 'http', host: 'example.com', port: 8080, path: '/dir'
      )
    end

    it "should match URLs on the same host, port and path" do
      expect(cookie.matches?(URI('http://example.com:8080/dir/page'))).to be(true)
    end

    it "should match URLs below the cookie path" do
      expect(cookie.matches?(URI('http://example.com:8080/dir/sub/page'))).to be(true)
    end

    it "should not match URLs outside of the cookie path" do
      expect(cookie.matches?(URI('http://example.com:8080/other'))).to be(false)
    end

    it "should not match path prefixes that are not directory boundaries" do
      expect(cookie.matches?(URI('http://example.com:8080/directory'))).to be(false)
    end

    it "should not match URLs on other hosts" do
      expect(cookie.matches?(URI('http://other.com:8080/dir/page'))).to be(false)
    end

    it "should match URLs on sub-domains of the cookie host" do
      expect(cookie.matches?(URI('http://www.example.com:8080/dir/page'))).to be(true)
    end

    it "should not match URLs on other ports" do
      expect(cookie.matches?(URI('http://example.com:9090/dir/page'))).to be(false)
    end

    context "when the cookie has no port" do
      it "should match URLs on any port" do
        cookie = described_class.new(name: 'a', value: '1', host: 'example.com')

        expect(cookie.matches?(URI('http://example.com:9090/'))).to be(true)
      end
    end

    context "when the cookie is secure" do
      let(:cookie) do
        described_class.new(
          name: 'a', value: '1', host: 'example.com', secure: true
        )
      end

      it "should match https URLs" do
        expect(cookie.matches?(URI('https://example.com/'))).to be(true)
      end

      it "should not match http URLs" do
        expect(cookie.matches?(URI('http://example.com/'))).to be(false)
      end
    end

    context "when the cookie is expired" do
      it "should not match any URL" do
        cookie = described_class.new(
          name: 'a', value: '1', host: 'example.com',
          expires: Time.now - 60
        )

        expect(cookie.matches?(URI('http://example.com/'))).to be(false)
      end
    end
  end

  describe "#to_s" do
    it "should format the cookie as a name=value pair" do
      cookie = described_class.new(name: 'a', value: '1', host: 'example.com')

      expect(cookie.to_s).to eq('a=1')
    end
  end
end
