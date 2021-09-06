$:.unshift File.join(File.dirname(__FILE__), 'lib')
require 'erb2rux/version'

Gem::Specification.new do |s|
  s.name     = 'erb2rux'
  s.version  = ::Erb2Rux::VERSION
  s.authors  = ['Cameron Dutro']
  s.email    = ['camertron@gmail.com']
  s.homepage = 'http://github.com/camertron/erb2rux'
  s.description = s.summary = 'Automatically convert .html.erb files into .rux files.'
  s.platform = Gem::Platform::RUBY

  s.add_dependency 'actionview', '~> 6.1'
  s.add_dependency 'parser', '~> 3.0'
  s.add_dependency 'unparser', '~> 0.6'

  s.require_path = 'lib'

  s.executables << 'erb2rux'

  s.files = Dir['{lib,spec}/**/*', 'Gemfile', 'LICENSE', 'CHANGELOG.md', 'README.md', 'Rakefile', 'erb2rux.gemspec']
end
