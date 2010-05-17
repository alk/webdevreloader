#!/usr/bin/env ruby

require 'socket'
require 'optparse'
require 'thread'

module Kernel
  def p_log(category, message, *extra)
    return if category.to_s =~ /_v$/ # suppress verbose messages
    return if category == :downstream && message =~ /^got something/
    return if category == :http
    STDOUT.print category, ": "
    STDOUT.print message
    ex = extra.map {|e| e.inspect}.join(", ")
    STDOUT.puts ex
  end
end

def test_exception
  raise "Asd"
rescue Exception
  $!
end

class Exception
  def diagnose
    class_str = self.class.to_s
    out = "" << self.backtrace[0] << ": " << class_str
    unless self.message.empty? || self.message == class_str
      out << ": " << message
    end
    out << "\n\t" << self.backtrace[1..-1].join("\n\t") << "\n"
  end
end

class Thread
  def self.run_diag(except = nil, &block)
    Thread.new do
      begin
        block.call
      rescue Exception
        unless except === $!
          p_log :thread_diag, $!.diagnose
        end
        raise
      end
    end
  end
end

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

$kill_signal = "KILL"

def kill_child!(wait = false)
  p_log :child, "killing child!"
  Process.kill($kill_signal, -$child_pgrp) rescue nil
  Process.kill($kill_signal, $child_pgrp) rescue nil
  $child_pgrp, pid = nil, $child_pgrp
  $child_rd_pipe.close rescue nil
  $child_rd_pipe = nil
  if wait
    poll_for_condition do
      !port_busyness($child_port)
    end
    Process::waitpid(pid, Process::WNOHANG)
  end
end

at_exit do
  p_log :child_v, "atexit!"
  if $child_pgrp
    kill_child!
  end
end

$child_port = 3000
$child_spawn_timeout = 30

def child_alife?
  $child_rd_pipe.read_nonblock(1)
  raise "Cannot happen"
rescue Errno::EAGAIN
  true
rescue EOFError
  false
end

def spawn_child!
  p_log :child, "spawning child!"
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
  poll_for_condition($child_spawn_timeout) do
    raise "Failed to exec child" unless child_alife?
    port_busyness($child_port)
  end
  p_log :child, "child is ready"
rescue Exception
  if $child_pgrp
    kill_child!
  end
  raise $!
end

$interesting_files_patterns = ["vendor/**/*", "lib/**/*", "app/**/*", "config/**/*"]
$mtimes = {}

def collect_intersting_files!
  mtimes = $mtimes = {}
  names = $interesting_files_patterns.map {|p| Dir[p]}.flatten.sort.uniq
#  p_log :collect_intersting_files!, "names: ", names
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
    if st.mtime.to_i > mtime
      p_log :child, "change detected on: ", path
      return true
    end
  end
  false
end

def dir_watcher_hook
  unless $child_pgrp
    spawn_child!

    collect_intersting_files!

    return
  end

  p_log :child, "checking changes"
  if anything_changed?
    p_log :child, "changed!"
    kill_child!(true)
    p_log :child, "old worker is dead"
    dir_watcher_hook
  end
end

$dir_watcher_mutex = Mutex.new
$dir_watcher = lambda do
  $dir_watcher_mutex.synchronize do
    dir_watcher_hook
  end
end
$socket_factory = lambda {TCPSocket.new('127.0.0.1', $child_port)}

class Reloader
  class << self
    attr_accessor :dir_watcher
    attr_accessor :socket_factory
  end
  self.dir_watcher = $dir_watcher
  self.socket_factory = $socket_factory

  module Utils
    if defined?(Fcntl::FD_CLOEXEC)
      def set_cloexec(io)
        io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      end
    else
      def set_cloexec(io)
      end
    end

    HTTP_END_REQUEST_RE = /\r?\n\r?\n/m
    HTTP_HEADER_END_RE = /\r?\n/m

    def read_http_something(initial_data, io)
      out = initial_data.dup
      begin
        io.readpartial(16384, out)
        p_log :http, "got out: ", out
      end while out !~ HTTP_END_REQUEST_RE

      offset = $~.begin(0)
      request_length = $~.end(0)
      request = out[0, offset]

      headers = request.split(HTTP_HEADER_END_RE)
      first_line = headers.shift
      headers = headers.inject({}) do |h, line|
        name, value = line.split(':', 2)
        h[name.downcase.strip] = value.strip
        h
      end

      # TODO: inspect other non-postable methods
      if first_line =~ /^(GET |HEAD )/
        return [out[0, request_length], out[request_length..-1]]
      end

      # transfer_coding = headers['transfer-coding']
      # if transfer_coding
      #   unless transfer_coding == 'chunked'
      #     raise "unsupported transfer-coding: #{transfer_coding}"
      #   end

      #   while out[request_length..-1] !~ /([0-9A-Fa-f]+).*?\n\r?/ && request_length + 4096 < out.length
      #     io.readpartial(16384, out)
      #   end

      #   raise "missing chunk-size" unless $~
      #   request_length += $~.end
      #   chunk_size = $1.to_i(16)
      # # HERE
      # end

      if headers['content-length']
        length = headers['content-length'].to_i
        length += request_length
        if out.size < length
#          p_log :http, "reading: ", length - out.size
          out << io.read(length - out.size)
        end
        raise if out.size < length
        p_log :http, "out_diag: ", length, out.length
        return [out[0,length].dup,
                out[length..-1].dup]
      end

      while true
        begin
          io.readpartial(16384, out)
        rescue EOFError
          break
        end
      end

      [out, ""]
    rescue EOFError
      return ["", out] if out.size == initial_data.size
      raise "Partial request or response"
    end
  end

  include Utils

  class UpstreamConnection
    include Utils

    def initialize(socket, downstream)
      @socket = socket
      @downstream = downstream
      @buffer = ""
    end

    def loop_iteration
      request, @buffer = read_http_something(@buffer, @socket)
      return :eof if request.empty?
      @downstream.proxy_request(request)
    end

    def loop
      while self.loop_iteration != :eof
      end
      close
    end

    def close
      p_log :upstream, "closing"
      @socket.close rescue nil
      @downstream.close
    end
  end

  class DownstreamConnection
    include Utils

    def initialize(socket, upstream_socket)
      @socket = socket
      @thread = Thread.run_diag(InterruptWork) {self.run_thread_loop!}
      @process_mutex = Mutex.new
      @process_cvar = ConditionVariable.new
      @response_counter = 0
      @upstream_socket = upstream_socket
      @closed = false
    end

    def proxy_request(request)
      @process_mutex.synchronize do
        raise EOFError if @socket.closed?
        p_log :downstream_v, "sending: #{request.inspect}"
        @socket << request
        counter = @response_counter
        while @response_counter == counter
          @process_cvar.wait(@process_mutex)
        end
      end
    end

    class InterruptWork < Exception
    end

    def close
      return if @socket.closed?

      @socket.close_write
      @thread.raise InterruptWork
      begin
        @thread.join
      rescue InterruptWork
        # ignore
      end
      @socket.close
    end

    def run_thread_loop!
      while true
        response, extra = read_http_something("", @socket)
        break if response.empty?

        p_log :downstream, "got something: #{response.inspect}"
        raise unless extra.empty?
        @upstream_socket << response

        @process_mutex.synchronize do
          @response_counter += 1
          @process_cvar.signal
          if response == ""
            @socket.close
            return
          end
        end
      end
      @socket.close
    end
  end

  def initialize(port=8080)
    @server = TCPServer.new(port)
    set_cloexec(@server)
  end
  def loop
    Reloader.dir_watcher.call
    while true
      socket = @server.accept
      set_cloexec(socket)
      Reloader.dir_watcher.call
      downstream_socket = Reloader.socket_factory.call
      set_cloexec(downstream_socket)
      downstream = DownstreamConnection.new(downstream_socket, socket)
      yield UpstreamConnection.new(socket, downstream)
    end
  end
end

Reloader.new().loop do |child_connection|
  Thread.run_diag do
    child_connection.loop
  end
end
