# frozen_string_literal: true

module Vulnerabilities
  # Dalle corrispondenze OSV alle righe che l'utente vede: apre le nuove, tiene vive quelle che
  # persistono, chiude quelle sparite.
  #
  # Tre transizioni, e una che NON facciamo:
  # - assente → `open`: vulnerabilità nuova, è quella che genera l'avviso e l'eventuale ticket;
  # - presente e ancora colpita → si aggiorna `last_seen_at` (e `fixed_version`, che può comparire
  #   dopo, quando l'advisory viene corretto);
  # - presente e non più colpita → `resolved`: il pacchetto è stato aggiornato o rimosso;
  # - una voce `ignored` NON torna aperta da sola. Qualcuno ha già valutato quel rischio; rimetterla
  #   in lista a ogni scansione significherebbe ignorare la sua decisione.
  #
  # Ritorna i finding APERTI ADESSO per la prima volta: sono l'unico insieme su cui ha senso
  # avvisare qualcuno.
  class RecordFindings < ApplicationService
    Outcome = Data.define(:opened, :reopened_count, :resolved_count, :still_open_count,
                          :unverified_count)

    def initialize(project:, matches:, packages:, unverified_manifest_ids: [], now: Time.current)
      @project = project
      @matches = matches
      @packages = packages
      # I manifest che questa scansione NON è riuscita a leggere: non sono un dettaglio diagnostico,
      # sono il pezzo di progetto su cui non abbiamo il diritto di dire niente (CYRA-810).
      @unverified_manifest_ids = Array(unverified_manifest_ids)
      @now = now
    end

    def call
      opened = []
      touched_ids = []

      packages_by_coordinate.each do |coordinate, packages|
        advisories = @matches[coordinate]
        next if advisories.blank?

        packages.each do |package|
          advisories.each do |advisory|
            finding, created = upsert(package, advisory, coordinate)
            touched_ids << finding.id
            opened << finding if created
          end
        end
      end

      resolved = resolve_disappeared(touched_ids)
      Result.ok(Outcome.new(opened: opened, reopened_count: 0, resolved_count: resolved,
                            still_open_count: touched_ids.size - opened.size,
                            unverified_count: @unverified_manifest_ids.size))
    end

    private

    # Più manifest dello stesso progetto possono dichiarare la stessa coppia nome+versione (un
    # monorepo con due app Rails): la corrispondenza OSV è una sola, i finding sono uno per pacchetto.
    def packages_by_coordinate
      @packages.group_by { |package| package.osv_key }
    end

    def upsert(package, advisory, coordinate)
      _ecosystem, name, version = coordinate
      finding = Vulnerabilities::Finding.find_by(package_id: package.id, advisory_id: advisory.id)

      if finding
        attributes = { last_seen_at: @now,
                       fixed_version: advisory.fixed_version_for(ecosystem: package.ecosystem,
                                                                 name: name, version: version) }
        # Una voce risolta che ricompare è tornata a essere vera: la riapriamo. Una ignorata no.
        attributes[:status] = :open if finding.status_resolved?
        attributes[:resolved_at] = nil if finding.status_resolved?
        finding.update!(attributes)
        return [ finding, false ]
      end

      created = Vulnerabilities::Finding.create!(
        project: @project, package: package, advisory: advisory,
        fixed_version: advisory.fixed_version_for(ecosystem: package.ecosystem, name: name,
                                                  version: version),
        status: :open, first_seen_at: @now, last_seen_at: @now
      )
      [ created, true ]
    rescue ActiveRecord::RecordNotUnique
      # Due scansioni concorrenti sullo stesso progetto: la seconda rilegge invece di fallire.
      [ Vulnerabilities::Finding.find_by!(package_id: package.id, advisory_id: advisory.id), false ]
    end

    # Ciò che era aperto e non è più stato toccato da questa scansione non descrive più il progetto —
    # a patto che questa scansione l'abbia davvero guardato.
    #
    # Le righe che pendono da un lockfile non letto restano dove sono: chiuderle vorrebbe dire
    # dichiarare scomparso ciò che abbiamo solo smesso di osservare, e la sicurezza del progetto
    # migliorerebbe proprio quando il controllo peggiora (CYRA-810). Un lockfile RIMOSSO dal
    # repository è un'altra cosa e non passa di qui: sparisce con i suoi pacchetti, e con loro le
    # loro vulnerabilità.
    def resolve_disappeared(touched_ids)
      scope = @project.vulnerability_findings.status_open
      scope = scope.where.not(id: touched_ids) if touched_ids.any?
      scope = scope.where.not(package_id: unverified_package_ids) if @unverified_manifest_ids.any?
      scope.update_all(status: Vulnerabilities::Finding.statuses[:resolved], resolved_at: @now,
                       updated_at: @now)
    end

    def unverified_package_ids
      Vulnerabilities::Package.where(manifest_id: @unverified_manifest_ids).select(:id)
    end
  end
end
