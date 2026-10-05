# frozen_string_literal: true

require "resolv"
require "ipaddr"

# Guard anti-SSRF condiviso (Uptime::Ping, Notifications::Deliver::Webhook): una URL fornita dall'utente
# non deve poter raggiungere la rete interna. Blocca schemi non-http(s) e host che risolvono a
# indirizzi privati/loopback/link-local/metadata. Il DNS-rebinding (TOCTOU tra validazione e connect)
# è chiuso dai chiamanti: risolvono l'IP UNA volta con `resolved_public_address` e lo pinnano sulla
# connessione (`Net::HTTP#ipaddr=`), così l'host non viene ri-risolto al momento del connect.
module NetworkGuard
  BLOCKED_RANGES = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15",
    "224.0.0.0/4", "240.0.0.0/4", "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  # Tempi limite (in secondi) della risoluzione DNS: due tentativi progressivi per nameserver. Senza
  # questi Resolv userebbe il resolver di sistema SENZA timeout: un dominio con nameserver morti
  # bloccherebbe un thread job per decine di secondi, e con soli 3 thread (queue.yml) tre domini così
  # fermano ingest, uptime e alerting (CYRA-273).
  DNS_TIMEOUTS = [ 2, 3 ].freeze

  module_function

  # true se la URL è sicura da contattare (schema http/https + nessun indirizzo interno).
  def safe_url?(raw_url)
    uri = URI.parse(raw_url.to_s)
    return false unless %w[http https].include?(uri.scheme)

    !private_target?(uri.host)
  rescue URI::InvalidURIError
    false
  end

  # Blocca se UNO degli indirizzi dell'host è interno. Host già IP letterale → controllato senza DNS.
  def private_target?(host)
    return true if host.blank?

    addresses = ip_literal?(host) ? [ host ] : resolve(host)
    return true if addresses.empty?

    addresses.any? { |addr| blocked_address?(addr) }
  end

  # Risolve l'host UNA volta e ritorna il primo indirizzo, o nil se blank/irrisolvibile o se UNO
  # qualsiasi degli indirizzi è interno (host con record misti pubblico+interno = sospetto → nil).
  # Il chiamante pinna questo IP sulla connessione: nessuna seconda risoluzione, niente rebinding.
  def resolved_public_address(host)
    return nil if host.blank?

    addresses = ip_literal?(host) ? [ host ] : resolve(host)
    return nil if addresses.empty? || addresses.any? { |addr| blocked_address?(addr) }

    addresses.first
  end

  # Risoluzione DNS con timeout esplicito (DNS_TIMEOUTS). getaddresses (plurale) non solleva: ritorna
  # [] se non trova nulla. Il rescue copre i guasti del resolver (timeout scaduto, resolv.conf
  # illeggibile) mappandoli su [] → i chiamanti trattano l'host come irrisolvibile (bloccato/nil).
  def resolve(host)
    dns = Resolv::DNS.new
    dns.timeouts = DNS_TIMEOUTS
    dns.getaddresses(host).map(&:to_s)
  rescue Resolv::ResolvError, IOError, SystemCallError
    []
  ensure
    dns&.close
  end

  def blocked_address?(addr)
    ip = IPAddr.new(addr).native
    BLOCKED_RANGES.any? { |range| range.include?(ip) }
  rescue IPAddr::Error
    true
  end

  def ip_literal?(host)
    IPAddr.new(host)
    true
  rescue IPAddr::Error
    false
  end
end
