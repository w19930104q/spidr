require 'spidr/cookie_jar'

require 'spec_helper'

describe CookieJar do
  it "should retrieve cookies for the named host" do
    subject['zerosum.org'] = {'admin' => 'ofcourseiam'}

    expect(subject['zerosum.org']).to eq({'admin' => 'ofcourseiam'})
  end

  it "should add a cookie to the jar" do
    subject['zerosum.org'] = {'admin' => 'ofcourseiam'}

    expect(subject['zerosum.org']).to eq({'admin' => 'ofcourseiam'})
  end

  it "should merge new cookies into the jar" do
    subject['zerosum.org'] = {'admin' => 'ofcourseiam'}
    subject['zerosum.org'] = {'other' => '1'}

    expect(subject['zerosum.org']).to eq({
      'admin' => 'ofcourseiam',
      'other' => '1'
    })
  end

  it "should override previous cookies in the jar" do
    subject['zerosum.org'] = {'admin' => 'ofcourseiam'}
    subject['zerosum.org'] = {'admin' => 'somethingcompletelydifferent'}

    expect(subject['zerosum.org']).to eq({
      'admin' => 'somethingcompletelydifferent'
    })
  end

  it "should clear all cookies" do
    subject['zerosum.org'] = {'cookie' => 'foobar'}
    subject.clear!

    expect(subject.size).to eq(0)
  end

  describe "dirty" do
    let(:dirty) { subject.instance_variable_get('@dirty') }

    it "should mark a cookie dirty after adding new params" do
      subject['zerosum.org'] = {'admin' => 'ofcourseiam'}
      subject['zerosum.org'] = {'other' => '1'}

      expect(dirty.include?('zerosum.org')).to eq(true)
    end

    it "should mark a cookie dirty after overriding params" do
      subject['zerosum.org'] = {'admin' => 'ofcourseiam'}
      subject['zerosum.org'] = {'admin' => 'nope'}

      expect(dirty.include?('zerosum.org')).to eq(true)
    end

    it "should un-mark a cookie as dirty after re-encoding it" do
      subject['zerosum.org'] = {'admin' => 'ofcourseiam'}
      subject['zerosum.org'] = {'admin' => 'nope'}

      expect(dirty.include?('zerosum.org')).to eq(true)

      subject.for_host('zerosum.org')

      expect(dirty.include?('zerosum.org')).to eq(false)
    end
  end

  describe "cookies_for_host" do
    it "should return an empty Hash for unknown hosts" do
      expect(subject.cookies_for_host('lol.com')).to be_empty
    end

    it "should return an empty Hash for hosts with no cookie params" do
      subject['lol.com'] = {}

      expect(subject.cookies_for_host('lol.com')).to be_empty
    end

    it "should return cookie parameters for the host" do
      subject['zerosum.org'] = {'admin' => 'ofcourseiam'}
      subject['zerosum.org'] = {'other' => '1'}

      cookie = subject.cookies_for_host('zerosum.org')

      expect(cookie['admin']).to eq('ofcourseiam')
      expect(cookie['other']).to eq('1')
    end

    it "should include cookies for the parent domain" do
      subject['zerosum.org'] = {'admin' => 'ofcourseiam'}
      subject['sub.zerosum.org'] = {'other' => '1'}

      cookie = subject.cookies_for_host('sub.zerosum.org')

      expect(cookie['admin']).to eq('ofcourseiam')
      expect(cookie['other']).to eq('1')
    end
  end

  describe "for_host" do
    it "should return nil for unknown hosts" do
      expect(subject.for_host('lol.com')).to be_nil
    end

    it "should return nil for hosts with no cookie params" do
      subject['lol.com'] = {}

      expect(subject.for_host('lol.com')).to be_nil
    end

    it "should encode single cookie params" do
      subject['zerosum.org'] = {'admin' => 'ofcourseiam'}

      expect(subject.for_host('zerosum.org')).to eq('admin=ofcourseiam')
    end

    it "should encode multiple cookie params" do
      subject['zerosum.org'] = {'admin' => 'ofcourseiam'}
      subject['zerosum.org'] = {'other' => '1'}

      cookie = subject.for_host('zerosum.org')

      expect(cookie).to include('admin=ofcourseiam')
      expect(cookie).to include('; ')
      expect(cookie).to include('other=1')
    end

    it "should include cookies for the parent domain" do
      subject['zerosum.org'] = {'admin' => 'ofcourseiam'}
      subject['sub.zerosum.org'] = {'other' => '1'}

      cookie = subject.for_host('sub.zerosum.org')

      expect(cookie).to include('admin=ofcourseiam')
      expect(cookie).to include('; ')
      expect(cookie).to include('other=1')
    end
  end

  describe "#from_response" do
    let(:url)      { URI('http://example.com:8080/dir/page') }
    let(:response) { double('response') }

    it "should store cookies bound to the URL of the response" do
      allow(response).to receive(:get_fields).with('Set-Cookie').and_return([
        'session=abc'
      ])

      subject.from_response(url,response)

      expect(subject['example.com']).to eq({'session' => 'abc'})
    end

    it "should return false when the response sets no cookies" do
      allow(response).to receive(:get_fields).with('Set-Cookie').and_return(nil)

      expect(subject.from_response(url,response)).to be(false)
    end
  end

  describe "#for_url" do
    let(:url) { URI('http://example.com:8080/dir/page') }

    def set_cookie(set_cookie,url)
      response = double('response')

      allow(response).to receive(:get_fields).with('Set-Cookie').and_return([
        set_cookie
      ])

      subject.from_response(url,response)
    end

    it "should return nil when no cookies match the URL" do
      expect(subject.for_url(url)).to be_nil
    end

    it "should return cookies set by a response for the URL" do
      set_cookie('session=abc',url)

      expect(subject.for_url(url)).to eq('session=abc')
    end

    it "should not return cookies set for another host" do
      set_cookie('session=abc',url)

      expect(subject.for_url(URI('http://other.com:8080/dir/page'))).to be_nil
    end

    it "should not return cookies set for another port" do
      set_cookie('session=abc',url)

      expect(subject.for_url(URI('http://example.com:9090/dir/page'))).to be_nil
    end

    it "should not return cookies set for another scheme" do
      set_cookie('session=abc; Secure',url)

      expect(subject.for_url(url)).to be_nil
    end

    it "should return secure cookies for HTTPS URLs" do
      set_cookie('session=abc; Secure',URI('https://example.com/dir/page'))

      expect(subject.for_url(URI('https://example.com/dir/page'))).to eq('session=abc')
    end

    it "should not return expired cookies" do
      set_cookie('session=abc; Max-Age=0',url)

      expect(subject.for_url(url)).to be_nil
    end

    it "should delete cookies when an expired cookie is set" do
      set_cookie('session=abc',url)
      set_cookie('session=abc; Max-Age=0',url)

      expect(subject.for_url(url)).to be_nil
    end

    it "should only return cookies whose path matches the URL path" do
      set_cookie('sub=1; Path=/sub',url)

      expect(subject.for_url(URI('http://example.com:8080/sub/page'))).to eq('sub=1')
      expect(subject.for_url(URI('http://example.com:8080/other'))).to be_nil
    end

    it "should return cookies for parent domains" do
      set_cookie('session=abc; Domain=example.com',URI('http://www.example.com/'))

      expect(subject.for_url(URI('http://example.com/'))).to eq('session=abc')
      expect(subject.for_url(URI('http://www.example.com/'))).to eq('session=abc')
      expect(subject.for_url(URI('http://other.com/'))).to be_nil
    end

    it "should return cookies set via []= for any port" do
      subject['example.com'] = {'session' => 'abc'}

      expect(subject.for_url(URI('http://example.com:9090/'))).to eq('session=abc')
    end
  end
end
