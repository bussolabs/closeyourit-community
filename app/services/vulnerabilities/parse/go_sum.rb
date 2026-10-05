# frozen_string_literal: true

module Vulnerabilities
  module Parse
    # `go.sum`. Due righe per modulo:
    #
    #   golang.org/x/net v0.17.0 h1:…
    #   golang.org/x/net v0.17.0/go.mod h1:…
    #
    # La seconda è il checksum del solo `go.mod` e descrive lo stesso modulo: tenerla produrrebbe un
    # doppione. `go.sum` non distingue dirette e transitive (quello lo sa `go.mod`), quindi qui
    # `direct` resta false per tutti: dichiararlo a caso sarebbe peggio che non dichiararlo.
    class GoSum < ApplicationService
      GO_MOD_SUFFIX = "/go.mod"
      # "v1.2.3", "v1.2.3+incompatible", "v0.0.0-20210101000000-abcdef123456"
      VERSION_FORMAT = /\Av\d/

      def initialize(content:)
        @content = content
      end

      def call
        seen = Set.new

        @content.to_s.each_line.filter_map do |line|
          name, raw_version, = line.split
          next if name.blank? || raw_version.blank?
          next if raw_version.end_with?(GO_MOD_SUFFIX)
          next unless raw_version.match?(VERSION_FORMAT)

          version = normalize(raw_version)
          next unless seen.add?([ name, version ])

          Dependency.new(name: name, version: version, direct: false)
        end
      end

      private

      # OSV accetta la versione Go con o senza la `v`; la togliamo per uniformarci a come la si legge
      # ovunque nell'interfaccia. `+incompatible` è un marcatore del sistema dei moduli, non parte
      # della versione pubblicata.
      def normalize(raw) = raw.delete_prefix("v").sub("+incompatible", "")
    end
  end
end
