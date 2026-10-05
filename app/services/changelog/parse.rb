# frozen_string_literal: true

module Changelog
  # Parser puro (nessun I/O) del formato Keep a Changelog:
  #   ## [x.y.z] - YYYY-MM-DD  → release (l'intestazione [Unreleased] viene ignorata)
  #   ### Label                → sezione (Added/Changed/Fixed/…)
  #   - voce                   → voce della sezione; le righe indentate seguenti la continuano
  # Ritorna un Array<Changelog::Release>.
  class Parse < ApplicationService
    RELEASE = /\A## \[(\d+\.\d+\.\d+)\] - (.+)\z/
    HEADING = /\A## \[/
    SECTION = /\A### (.+)\z/
    ITEM    = /\A- (.+)\z/
    CONT    = /\A\s+\S/

    def initialize(text)
      @text = text.to_s
    end

    def call
      @releases = []
      @current = @section = @item = nil

      @text.each_line { |raw| consume(raw.chomp) }
      flush_item

      @releases.map do |r|
        Release.new(version: r[:version], date: r[:date], sections: r[:sections])
      end
    end

    private

    def consume(line)
      if (m = line.match(RELEASE))
        open_release(version: m[1], date: m[2].strip)
      elsif line.match?(HEADING)          # [Unreleased] o altra intestazione senza semver
        close_release
      elsif @current && (m = line.match(SECTION))
        open_section(m[1].strip)
      elsif @section && (m = line.match(ITEM))
        open_item(m[1])
      elsif @item && line.match?(CONT)
        @item = "#{@item} #{line.strip}"
      end
    end

    def open_release(version:, date:)
      flush_item
      @current = { version:, date:, sections: [] }
      @releases << @current
      @section = nil
    end

    def close_release
      flush_item
      @current = @section = nil
    end

    def open_section(label)
      flush_item
      @section = { label:, items: [] }
      @current[:sections] << @section
    end

    def open_item(text)
      flush_item
      @item = text
    end

    # Chiude la voce corrente, normalizzandola (whitespace collassato) e accodandola alla sezione.
    def flush_item
      @section[:items] << @item.squish if @section && @item
      @item = nil
    end
  end
end
