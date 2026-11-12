require 'rspec'
require 'simplecov'
require 'spidr/version'

# run the example Sinatra apps in the test environment, so that they
# accept requests for any host-name
ENV['RACK_ENV'] ||= 'test'

include Spidr

SimpleCov.start
