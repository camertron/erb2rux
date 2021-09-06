$:.push(__dir__)

require 'rspec'
require 'erb2rux'
require 'pry-byebug'

Dir.chdir(__dir__) do
  Dir['support/*.rb'].each { |f| require f }
end

module SpecHelpers
end

RSpec.configure do |config|
  config.include SpecHelpers
end
