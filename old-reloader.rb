#!/usr/bin/env ruby

require 'pp'
require 'socket'

module Reloader
  module Protocol
    def write_sized(io, data)
      data = Marshal.dump(data)
      io.write([[data.size].pack('V'), data].join)
      io.flush
    end

    def read_sized(io)
      data = io.read(4)
      raise if data.size != 4
      size = data.unpack('V')[0]
      raise unless size.kind_of?(Numeric) && size >= 0
      Marshal.load(io.read(size))
    end

    def write_request(io, env)
      env = env.dup
      env.delete("rack.errors")
      env['rack.input'] = env['rack.input'].read
      write_sized(io, env)
    end

    def read_request(io)
      env = read_sized(io)

      env['rack.errors'] = $stderr
      env['rack.input'] = StringIO.new(env['rack.input'])
      env
    end

    def write_response(io, resp)
      return write_sized(io, resp) unless resp.kind_of?(Array)

      status, headers, body = *resp
      status = status.to_s
      headers = headers.inject({}) do |hash, (k,v)|
        v = if k.downcase == 'set-cookie'
              v.to_a #.map {|s| s.to_s}
            else
              v.to_s
            end
        hash[k.to_s] = v.to_s
        hash
      end
      resbody = ""
      body.each {|part| resbody << part}
      body.close if body.respond_to?(:close)
      resp = [status, headers, [resbody]]

      write_sized(io, resp)
    end

    def read_response(io)
      read_sized(io)
    end
  end

  module RequireTracker
    @@mtimes = {}
    def self.mtimes
      @@mtimes
    end

    def self.register_loaded(string)
      found = nil
      if string[0,1] == "/"
        c = File.join("/", string)
        if File.file?(c)
          found = c
        end
        c += ".rb"
        if File.file?(c)
          found = c
        end
      else
        $:.each do |dir|
          c = File.join(dir, string)
          if File.file?(c)
            found = c
            break
          end
          c << ".rb"
          if File.file?(c)
            found = c
            break
          end
        end
      end

      if found
        # puts "found: #{found}"
        self.mtimes[found] = File.mtime(found).to_f
      else
        # puts "not found: #{string}"
      end
    end

    EXCLUDE_PATTERNS = ['*/.git/*', './log/*', './tmp/*', './db/sphinx/*']
    FIND_INVOCATION = "find . #{EXCLUDE_PATTERNS.map {|p| "'!' -wholename '#{p}'"}.join(' -a ')} -type f -follow -mmin -59 -print0"

    def self.other_changed?
      return true if (Time.now.to_f - 3600) > @@mtime

      found = IO.popen(FIND_INVOCATION, "r") {|f| f.read}.split("\0")
      found.detect do |path|
        File.mtime(path).to_f > @@mtime
      end
    ensure
      @@mtime = Time.now.to_f
    end

    def self.anything_changed?
      return true if other_changed?

      self.mtimes.each do |name, mtime|
        new_mtime = File.mtime(name).to_f rescue nil
        if !new_mtime || new_mtime > mtime
          return true
        end
      end
      false
    end

    module InstanceMethods
      def require_with_tracking(string)
        rv = require_without_tracking(string)
        RequireTracker.register_loaded(string)
        rv
      end
      def load_with_tracking(string)
        rv = load_without_tracking(string)
        RequireTracker.register_loaded(string)
        rv
      end
    end

    def self.install!
      @@mtime = Time.now.to_f
      # Kernel.send(:include, InstanceMethods)
      # Kernel.module_eval do
      #   alias_method :require_without_tracking, :require
      #   alias_method :require, :require_with_tracking

      #   alias_method :load_without_tracking, :load
      #   alias_method :load, :load_with_tracking
      # end
    end
  end

  extend Protocol

module_function
  def run(app, options={})
    port = ENV['RELOADER_SERVER_PORT'].to_i
    unless port > 0
      raise "missing RELOADER_SERVER_PORT variable !"
    end
    socket = TCPSocket.new('127.0.0.1', port)

    loop do
      env = read_request(socket)
      if RequireTracker.anything_changed?
        write_response(socket, :respawn)
        exit
      end

      resp = app.call(env)
      write_response(socket, resp)
    end
  end

  def spawn_child!
    Thread.new do
      system __FILE__
    end
  end

  def process_request(env)
    while true
      unless @server
        puts "waiting client connection"
        @server = @master_server.accept
        puts "got connection"
        @server.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) if defined?(Fcntl::FD_CLOEXEC)
      end

      write_request(@server, env)
      rv = read_response(@server)
      return rv unless rv == :respawn

      @server.close
      @server = nil

      puts "got respawn. re-sending request"
      spawn_child!
    end
  end

  def start_server
    @master_server = TCPServer.new('127.0.0.1', 0)
    @master_server.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) if defined?(Fcntl::FD_CLOEXEC)
    ENV['RELOADER_SERVER_PORT'] = Socket.unpack_sockaddr_in(@master_server.getsockname)[0].to_s

    spawn_child!

    @server = nil

    options = {:Port => 3000}
    mutex = Mutex.new
    Rack::Handler::WEBrick.run(lambda do |env|
                                 mutex.synchronize do
                                   process_request(env)
                                 end
                               end, options) { trap(:INT) {Process.exit!}}
  end
end

Reloader::RequireTracker.install!

require 'rubygems'
gem 'rack', "~> 1.0.0"
require 'rack/handler'
#require 'xray/thread_dump_signal_handler'

module Rack
  module Handler
    class ReloadingHandler
      def self.run(*args)
        ::Reloader.run(*args)
      end
    end
  end
end

if ENV['RELOADER_SERVER_PORT']
  ARGV.replace(['ReloadingHandler'])
  load(File.expand_path(File.join(File.dirname(__FILE__), "script/server")))
else
  Reloader.start_server
end
