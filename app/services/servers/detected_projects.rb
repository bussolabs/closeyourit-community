# frozen_string_literal: true

module Servers
  # CYRA-471 — progetti RICONOSCIBILI dai dati della macchina (nomi dei container e dei database) ma
  # non ancora collegati a un suo environment. È solo un SUGGERIMENTO: il match per nome può sbagliare
  # (un database "app_production" e un progetto "App" non sono per forza la stessa cosa), quindi non
  # crea mai un collegamento — porta l'utente a confermarlo a mano dal progetto.
  #
  # Match volutamente conservativo: lo slug del progetto (nome ridotto a lettere e cifre) deve comparire
  # COME SEGMENTO INTERO fra i pezzi dei nomi rilevati (spezzati su ogni separatore), non come
  # sottostringa — così "app" non pesca "myapp". Solo progetti uptime-capable e visibili al viewer: sono
  # gli unici a cui una macchina si può davvero collegare (stesso gate di Connections::EnvironmentHost).
  class DetectedProjects < ApplicationService
    # Sotto le 3 lettere lo slug è troppo generico e pescherebbe mezzo mondo (stessa soglia dei
    # frammenti di container ignorati, Servers::Host#ignored_container_patterns_are_short).
    MIN_SLUG_LENGTH = 3

    def initialize(host:, projects:, containers: [], linked_project_ids: [])
      @host = host
      @projects = projects
      @containers = containers
      @linked_project_ids = Array(linked_project_ids).map(&:to_s)
    end

    def call
      segments = detected_segments
      return [] if segments.empty?

      candidate_projects.select do |project|
        slug = normalize(project.name)
        slug.length >= MIN_SLUG_LENGTH && segments.include?(slug)
      end.sort_by { |project| project.name.to_s.downcase }
    end

    private

    # I "segmenti" alfanumerici dei nomi rilevati sulla macchina: dai container (ultimo push) e dai
    # database dello snapshot. Es. "closeyourit-web-1a2b" → closeyourit/web/1a2b, "app_production" →
    # app/production. Sotto le 3 lettere si scartano (rumore).
    def detected_segments
      names = @containers.map { |container| container.name.to_s } + database_names
      names.flat_map { |name| name.downcase.split(/[^a-z0-9]+/) }
           .reject { |segment| segment.length < MIN_SLUG_LENGTH }
           .to_set
    end

    def database_names
      snapshot = @host.database_snapshot
      return [] unless snapshot.is_a?(Hash)

      Array(snapshot["databases"]).filter_map { |database| database["name"] if database.is_a?(Hash) }
    end

    # Solo progetti uptime-capable e non già collegati: where.not scarica in SQL l'esclusione (con lista
    # vuota non filtra nulla). Una sola query, nessun N+1: il name usato nel match è già caricato.
    def candidate_projects
      @projects.uptime_capable.where.not(id: @linked_project_ids).to_a
    end

    def normalize(value) = value.to_s.downcase.gsub(/[^a-z0-9]/, "")
  end
end
