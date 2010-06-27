#!/usr/bin/env ruby

require 'socket'
require 'optparse'
require 'thread'

require "rubygems"
require "xray/thread_dump_signal_handler" rescue nil

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

# simple recursive (for readers) rwlock that prefers writers over
# readers
class RWLock
  def initialize
    @mutex = Mutex.new
    @state = :free
    @shared_q = ConditionVariable.new
    @shared_counter = 0
    @exclusive_q = ConditionVariable.new

    @exclusive_requests = 0
  end

  def take_shared
    @mutex.synchronize do
      while true
        if @exclusive_requests == 0
          case @state
          when :free, :shared
            @shared_counter += 1
            @state = :shared
            return
          end
        end

        p_log :lock, "sleeping for shared lock"
        @shared_q.wait(@mutex)
      end
    end
  end

  def release_shared
    @mutex.synchronize do
      @shared_counter -= 1
      @state = :free if @shared_counter == 0
      @exclusive_q.signal
    end
  end

  def take_exclusive
    @mutex.synchronize do
      @exclusive_requests += 1
      while true
        if @state == :free
          @state = :exclusive
          return
        end

        p_log :lock, "sleeping for x-lock"
        @exclusive_q.wait(@mutex)
      end
    end
  end

  def release_exclusive
    @mutex.synchronize do
      @exclusive_requests -= 1

      @state = :free
      if @exclusive_requests > 0
        @exclusive_q.signal
      else
        @shared_q.signal
      end
    end
  end

  def cannot_raise
    yield
  rescue Exception
    puts "BUG!"
    raise
  end

  def synchronize_shared
    take_shared
    yield
  ensure
    cannot_raise do
      release_shared
    end
  end

  def synchronize_exclusive
    take_exclusive
    yield
  ensure
    cannot_raise do
      release_exclusive
    end
  end
end


$child_rd_pipe = nil
$child_pgrp = nil

$kill_signal = "KILL"

$child_port = 3000
$child_spawn_timeout = 30

module ChildController
  module_function

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
      begin
        Process.setpgid(Process.pid, 0)
      rescue Errno::EACCESS
      end
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
end

at_exit do
  p_log :child_v, "atexit!"
  if $child_pgrp
    ChildController.kill_child!
  end
end

$interesting_files_patterns = ["vendor/**/*", "lib/**/*", "app/**/*", "config/**/*"]
$mtimes = {}

module DirWatcher
  module_function

  def collect_interesting_files!
    mtimes = $mtimes = {}
    names = $interesting_files_patterns.map {|p| Dir[p]}.flatten.sort.uniq
    #  p_log :collect_interesting_files!, "names: ", names
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
end

$socket_factory = lambda {TCPSocket.new('127.0.0.1', $child_port)}

class Reloader
  class << self
    attr_accessor :socket_factory
  end
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

    def run
      loop_iteration
    ensure
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
      @upstream_socket = upstream_socket
    end

    def proxy_request(request)
      @socket << request

      response, extra = read_http_something("", @socket)
      if response.empty?
        p_log :downstream, "downstream closed on in-flight request"
        return :eof
      end

      p_log :downstream, "got something: #{response.inspect}"
      raise unless extra.empty?

      @upstream_socket << response
    end

    def close
      return if @socket.closed?
      @socket.close
    end
  end

  def initialize(port=8080)
    @server = TCPServer.new(port)
    set_cloexec(@server)
    @lock = RWLock.new
  end

  def check_dir!
    unless $child_pgrp
      DirWatcher.collect_interesting_files!
      ChildController.spawn_child!
    end

    p_log :child, "checking changes"
    if DirWatcher.anything_changed?
      p_log :child, "changed!"

      @lock.synchronize_exclusive do
        ChildController.kill_child!(true)
      end

      p_log :child, "old worker is dead"
      check_dir!
    end
  end

  def loop
    check_dir!
    lock = @lock

    while true
      socket = @server.accept
      set_cloexec(socket)

      check_dir!

      Thread.run_diag do
        p_log :upstream, "spawned new thread"
        lock.synchronize_shared do
          downstream_socket = Reloader.socket_factory.call
          set_cloexec(downstream_socket)
          downstream = DownstreamConnection.new(downstream_socket, socket)
          UpstreamConnection.new(socket, downstream).run
        end
      end
    end
  end
end

$server_port = 8080
$custom_patterns = false

opts = OptionParser.new
opts.banner = "Usage: #{File.basename($0)} [options] command..."
opts.on("-u", "--upstream-port=VAL", Integer) {|x| $server_port = x}
opts.on("-d", "--downstream-port=VAL", Integer) {|x| $child_port = x}
opts.on("-T", "--spawn-timeout=VAL", Float) {|x| $child_spawn_timeout = x}
opts.on("-s", "--kill-signal=VAL") {|x| $kill_signal = x}
opts.on("-w", "--watch=VAL") do |x|
  unless $custom_patterns
    $custom_patterns = true
    $interesting_files_patterns = []
  end
  $interesting_files_patterns << x
end
new_argv = opts.parse(*ARGV)
ARGV.replace(new_argv)

if ARGV.empty?
  puts "Need command to spawn child"
  exit 1
end

p_log :opts, "child_port: ", $child_port
p_log :opts, "server_port: ", $server_port
p_log :opts, "interesting_files_patterns: ", $interesting_files_patterns

Reloader.new($server_port).loop
