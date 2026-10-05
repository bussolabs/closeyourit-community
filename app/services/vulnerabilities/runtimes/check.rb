# frozen_string_literal: true

module Vulnerabilities
  module Runtimes
    # Confronta i runtime dichiarati dal repository col calendario di endoflife.date e scrive lo stato
    # di supporto di ciascuno.
    #
    # Il ciclo si sceglie per PREFISSO della versione dichiarata (`3.4.2` → ciclo `3.4`), preferendo
    # il più specifico: `nodejs` ha sia `24` sia `24.1`, e prendere il primo che combacia darebbe la
    # data sbagliata.
    #
    # Ritorna gli stati appena diventati `eol` o `ending_soon`: sono quelli su cui vale un avviso.
    # Uno stato che era già in allarme ieri non ne genera un altro oggi.
    class Check < ApplicationService
      def initialize(project:, files:, client: Vulnerabilities::Eol::Client.new, now: Time.current)
        @project = project
        @files = files
        @client = client
        @now = now
      end

      def call
        runtimes = declared
        return Result.ok([]) if runtimes.empty?

        changed = runtimes.filter_map { |runtime| upsert(runtime) }
        prune(runtimes.map(&:name))

        Result.ok(changed)
      rescue Vulnerabilities::Eol::Client::Error => e
        # Il calendario è irraggiungibile: teniamo ciò che sappiamo. Declassare tutto a "supportato"
        # perché non abbiamo potuto chiedere sarebbe un falso rassicurante.
        Result.err(AppError.new(e.message, code: e.code, status: e.status))
      end

      private

      def declared
        @files.flat_map do |path, content|
          Declared.call(path: path, content: content)
        end.uniq(&:name)
      end

      def upsert(runtime)
        cycle = cycle_for(runtime)
        state = Vulnerabilities::RuntimeStatus.state_for(cycle[:eol_on], @now.to_date)

        status = @project.vulnerability_runtime_statuses.find_or_initialize_by(name: runtime.name)
        was_calm = status.new_record? || status.state_supported?
        status.assign_attributes(version: runtime.version, cycle: cycle[:cycle], eol_on: cycle[:eol_on],
                                 latest: cycle[:latest], state: state, source_path: runtime.source_path,
                                 checked_at: @now)
        status.save!

        # Solo il passaggio dalla calma all'allarme merita un avviso.
        status if was_calm && !status.state_supported?
      end

      def cycle_for(runtime)
        cycles = @client.cycles(runtime.name)
        return { cycle: nil, eol_on: nil, latest: nil } if cycles.blank?

        # Il ciclo più specifico fra quelli che sono un prefisso della versione dichiarata: "24.1"
        # batte "24" quando la versione è 24.1.0.
        match = cycles.select { |cycle| prefix?(runtime.version, cycle["cycle"]) }
                      .max_by { |cycle| cycle["cycle"].to_s.length }

        { cycle: match&.dig("cycle"), eol_on: parse_date(match&.dig("eol")), latest: match&.dig("latest") }
      end

      def prefix?(version, cycle)
        cycle = cycle.to_s
        return false if cycle.blank?

        version == cycle || version.start_with?("#{cycle}.")
      end

      # `eol` può essere una data, `true` (già finito, senza data) o `false` (ancora supportato).
      def parse_date(value)
        return nil if value.blank? || value == false
        return @now.to_date if value == true

        Date.parse(value.to_s)
      rescue Date::Error
        nil
      end

      # Un runtime tolto dal repository non deve restare a lamentarsi per sempre.
      def prune(names)
        @project.vulnerability_runtime_statuses.where.not(name: names).destroy_all
      end
    end
  end
end
