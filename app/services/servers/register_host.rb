# frozen_string_literal: true

module Servers
  # Auto-registrazione dell'host al push (stile Beszel universal token): risolve o crea l'host per
  # [organization, fingerprint]. Race-safe sull'unique index: due primi push concorrenti convergono
  # sulla stessa riga. Sincrono nel controller (un host revocato deve ricevere 403 SUBITO).
  class RegisterHost < ApplicationService
    def initialize(organization:, fingerprint:, hostname: nil, enrollment_token: nil)
      @organization = organization
      @fingerprint = fingerprint
      @hostname = hostname
      @enrollment_token = enrollment_token
    end

    def call
      host = Servers::Host.find_by(organization: @organization, fingerprint: @fingerprint) || create_host
      Result.ok(host)
    end

    private

    def create_host
      # CYRA-469 — il codice di accesso si registra SOLO alla nascita dell'host: da lì la pagina dei
      # codici sa quante macchine sono collegate a ciascuno. Non lo si tocca sugli host esistenti —
      # con quale codice si erano registrati non è un dato che possediamo, e non lo si inventa.
      Servers::Host.create!(
        organization: @organization,
        fingerprint: @fingerprint,
        name: @hostname.presence || @fingerprint,
        hostname: @hostname,
        enrollment_token: @enrollment_token
      )
    rescue ActiveRecord::RecordNotUnique
      # Perso il race col push gemello: la riga ormai esiste, riusala.
      Servers::Host.find_by!(organization: @organization, fingerprint: @fingerprint)
    end
  end
end
