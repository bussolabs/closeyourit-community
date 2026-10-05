# frozen_string_literal: true

module Errors
  class Symbolication
    module Java
      # Build a single Java stack from the received graph, never from array order.
      class Stack < ApplicationService
        NAME = /\A[\p{L}_$][\p{L}\p{N}_$]*(?:[.$][\p{L}\p{N}_$]+)*\z/

        def initialize(values:)
          @values = values
          @rows = []
          @visited = []
        end

        def call
          reject! unless @values.is_a?(Array) && @values.size.between?(1, 100) && @values.all? { |value| value.is_a?(Hash) }
          @nodes = @values.each_with_index.map { |value, index| node(value, index) }
          prepare_ids!
          root = @nodes.select { |value| value[:parent].nil? }
          reject! unless root.size == 1 && !root.first[:suppressed]
          visit(root.first, prefix: "", caption: "", depth: 0)
          reject! unless @visited.size == @nodes.size
          @rows
        end

        private

        def prepare_ids!
          ids = @nodes.map { |value| value[:id] }
          if ids.all?(&:nil?)
            reject! if @nodes.any? { |value| value[:parent] || value[:suppressed] }
            # Legacy events without mechanisms define a deepest-cause-first chain.
            @nodes.each_with_index { |value, index| value.merge!(id: index, parent: index == @nodes.size - 1 ? nil : index + 1) }
          else
            reject! if ids.any?(&:nil?) || ids.uniq.size != ids.size
          end
        end

        def node(value, index)
          mechanism = value["mechanism"] || {}
          reject! unless mechanism.is_a?(Hash)
          id, parent = mechanism.values_at("exception_id", "parent_id")
          reject! unless [ id, parent ].compact.all? { |number| number.is_a?(Integer) && number.between?(0, 2**31 - 1) }
          { id: id, parent: parent, suppressed: mechanism["type"] == "suppressed", value: value, index: index }
        end

        def visit(node, prefix:, caption:, depth:)
          reject! if depth > 32 || @visited.include?(node[:id])
          @visited << node[:id]
          value = node[:value]
          type = name(value["type"])
          mod = value["module"]
          type = "#{name(mod)}.#{type}" if mod.present? && !type.start_with?("#{mod}.")
          append("#{prefix}#{caption}#{type}", node[:index], nil, "header")
          frames = value.fetch("stacktrace", {}).fetch("frames", [])
          reject! unless frames.is_a?(Array)
          frames.each_with_index.to_a.reverse_each do |frame, index|
            append("#{prefix}\tat #{frame_line(frame)}", node[:index], index, "frame")
          end
          children = @nodes.select { |child| child[:parent] == node[:id] }
          causes, suppressed = children.partition { |child| !child[:suppressed] }
          reject! if causes.size > 1
          suppressed.each { |child| visit(child, prefix: "#{prefix}\t", caption: "Suppressed: ", depth: depth + 1) }
          causes.each { |child| visit(child, prefix: prefix, caption: "Caused by: ", depth: depth + 1) }
        rescue NoMethodError, TypeError
          reject!
        end

        def frame_line(frame)
          reject! unless frame.is_a?(Hash)
          mod = name(frame["module"])
          function = frame["function"]
          reject! unless %w[<init> <clinit>].include?(function) || (function.is_a?(String) && function.match?(NAME))
          "#{mod}.#{function}(#{position(frame)})"
        end

        def position(frame)
          line = frame["lineno"]
          reject! unless line.nil? || (line.is_a?(Integer) && line.between?(0, 2**31 - 1))
          if frame["native"] == true
            "Native Method"
          elsif frame["filename"].nil?
            line.nil? ? "Unknown Source" : "Unknown Source:#{line}"
          else
            file = frame["filename"]
            reject! unless file.is_a?(String) && file.valid_encoding? && file.bytesize <= 2048 && !file.match?(/[\r\n\x00():]/)
            line.nil? ? file : "#{file}:#{line}"
          end
        end

        def name(value)
          reject! unless value.is_a?(String) && value.bytesize <= 2048 && value.match?(NAME)
          value
        end

        def append(line, exception_index, frame_index, kind)
          reject! if @rows.size >= 500 || line.bytesize > 4096
          @rows << { "line" => line, "exception_index" => exception_index, "frame_index" => frame_index, "kind" => kind }
        end

        def reject!
          raise ::Artifacts::Rejected, "unsupported_stack"
        end
      end
    end
  end
end
