#!/usr/bin/env ruby

require 'socket'
require 'optparse'

def port_busyness(port)
  TCPSocket.new('127.0.0.1', port).close
  true
rescue Errno::ECONNREFUSED
  false
end

def poll_for_condition(timeout=5)
  target = Time.now.to_f + timeout
  begin
    return if yield
    sleep 0.05
  end while (Time.now.to_f <= target)
  raise Errno::ETIMEDOUT
end

$child_rd_pipe = nil
$child_pgrp = nil

def kill_child!
  Process.kill("KILL", -$child_pgrp) rescue nil
  Process.kill("KILL", $child_pgrp) rescue nil
  $child_pgrp = nil
  $child_rd_pipe.close rescue nil
  $child_rd_pipe = nil
end

at_exit do
  if $child_pgrp
    kill_child!
  end
end

$child_port = 3000

def child_alife?
  $child_rd_pipe.read_nonblock(1)
rescue Errno::EAGAIN
  true
rescue EOFError
  false
end

def spawn_child!
  $child_pgrp = nil
  rd, wr = IO.pipe
  $child_pgrp = fork do
    rd.close
    Process.setpgid(Process.pid, 0)
    begin
      exec(*ARGV)
    rescue Exception
      puts "failed to exec: #{$!.inspect}"
    end
  end
  wr.close
  $child_rd_pipe = rd
  Process.setpgid($child_pgrp, $child_pgrp)
  poll_for_condition(15) do
    raise "Failed to exec child" unless child_alife?
    port_busyness($child_port)
  end
rescue Exception
  if $child_pgrp
    kill_child!
  end
  raise $!
end

$interesting_files_patterns = ["vendor/**", "lib/**", "app/**", "config/**"]
$mtimes = {}

def collect_intersting_files!
  mtimes = $mtimes = {}
  names = $interesting_files_patterns.map {|p| Dir[p]}.flatten.sort.uniq
  names.each do |path|
    st = begin
           File.stat(path)
         rescue Errno::ENOENT
           next
         end
    next unless st.file?
    mtimes[path] = st.mtime.to_i
  end
end

def anything_changed?
  $mtimes.each do |path, mtime|
    st = begin
           File.stat(path)
         rescue Errno::ENOENT
           return true
         end
    return true if st.mtime.to_i > mtime
  end
  false
end

def dir_watcher_hook
  unless $child_pgrp
    spawn_child!

    collect_intersting_files!

    return
  end

  if anything_changed?
    kill_child!
    dir_watcher_hook
  end
end

$dir_watcher = lambda {dir_watcher_hook}
$socket_factory = lambda {TCPServer.new('127.0.0.1', $child_port)}

class Reloader
  class << self
    attr_accessor :dir_watcher
    attr_accessor :socket_factory
  end

  module Utils
    if defined?(Fcntl::FD_CLOEXEC)
      def set_cloexec(io)
        io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      end
    else
      def set_cloexec(io)
      end
    end
  end

  include Utils

  class Connection
    include Utils

    def initialize(socket)
      @socket = socket
      @downstream_dead = false
      @downstream = nil
    end

    HTTP_END_REQUEST_RE = /\n\r?\n\r?/m
    HTTP_HEADER_END_RE = /\n\r?/m

    def loop_further
      return unless buffer =~ HTTP_END_REQUEST_RE
      offset = $~.begin
      request = buffer[0, offset]

      headers = request.split(HTTP_HEADER_END_RE)
      first_line = headers.shift
      headers.collect! do |line|
        name, value = line.split(':', 2)
        [name.downcase.strip, value.strip]
      end

      headers_map = headers.inject({}) do |h, (k,v)|
        h[k] = v
        h
      end

      if headers_map['transfer-coding']
        raise "transfer-coding is not supported!"
      end

      if headers_map['content-length']
        length = headers_map['content-length'].to_i
        [:proxy_fixed_length, length]
      else
        [:proxy_and_close]
      end
    end

    def read_some!
      initial_bufsize = @buffer.size
      @socket.readpartial(1048576, @buffer)
      @buffer.size - initial_bufsize
    rescue EOFError
      0
    end

    def get_client
      if @downstream_dead
        raise "Keepalive connection closed at downstream end"
      end
      # we race here w.r.t @downstream_dead, but I think it's
      # harmless, 'cause this can happen only for http-keepalive
      # connections and clients expect server to close connection at
      # any time
      return @downstream if @downstream
      @downstream = Reloader.socket_factory.call
      @reader_thread = Thread.new do
        begin
          while true
            @socket << @downstream.readpartial(8192)
          end
        rescue EOFError
          # ignore
        ensure
          @socket.close_write
          @downstream_dead = true
        end
      end
      @downstream
    end

    def proxy_and_close
      client = self.get_client
      client << @buffer

      while true
        @buffer = ""
        readen = self.read_some!
        break if readen == 0
        client << @buffer
      end
      client.close_write
    end

    def proxy_fixed_length(length)
      client = self.get_client
      client << @buffer
      client << @socket.read(length)
    end

    def loop
      @buffer = ""

      done = false
      begin
        readen = self.read_some!
        further = loop_further(@buffer)
        if further
          Reloader.dir_watcher.call
          if self.send(*further)
            done = true
            break
          end
        end
      end while readen > 0
      unless done
        raise "Incomplete request!: #{@buffer.inspect}"
      end
      @downstream.close_write
      @reader_thread.join
    ensure
      close!
    end

    def close!
      if @downstream
        @downstream.close rescue nil
        @reader_thread.join
      end
      @socket.close rescue nil
    end
  end

  def initialize(port=8080)
    @server = TCPServer.new(port)
    set_cloexec(socket)
  end
  def loop
    while true
      socket = @server.accept
      set_cloexec(socket)
      yield Connection.new(socket)
    end
  end
end

Reloader.new().loop do |child_connection|
  child_connection.loop
end
