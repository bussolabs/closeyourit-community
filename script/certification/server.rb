# frozen_string_literal: true

require_relative "runtime"
Certification::Runtime.boot!
require "puma"

port = Integer(ENV.fetch("CERTIFICATION_PORT"), 10)
raise "Invalid certification port" unless (1024..65_535).cover?(port)

server = Puma::Server.new(Rails.application)
server.add_tcp_listener("127.0.0.1", port)
%w[INT TERM].each { |signal| Signal.trap(signal) { Thread.new { server.stop(true) } } }
server.run.join
