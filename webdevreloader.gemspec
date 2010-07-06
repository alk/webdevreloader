# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.platform = Gem::Platform::RUBY
  s.summary = "Smart web application reloader"
  s.name = "webdevreloader"
  s.version = "0.6"
  s.author = "Aliaksey Kandratsenka"
  s.email = "alk@tut.by"
  s.require_paths = ['bin']
  s.executables = ['reloader']
  s.default_executable = 'reloader'
  s.files = ['README', *Dir['bin/**/*']]
  s.has_rdoc = false
  s.description = "reloader watches your application files and reloads your app when something changes"
end
