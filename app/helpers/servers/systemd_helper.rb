# frozen_string_literal: true

module Servers
  # Le UNIT di sistema di una macchina: attive, in errore, in transizione, e la distinzione che conta
  # — una unit ferma per costruzione non è una unit rotta (CYRA-742).
  module SystemdHelper
    SYSTEMD_STATE_COLORS = { "active" => :emerald, "failed" => :red, "activating" => :amber,
                             "deactivating" => :amber, "reloading" => :amber, "inactive" => :gray }.freeze
    def server_systemd_color(state) = SYSTEMD_STATE_COLORS.fetch(state.to_s, :gray)

    # CYRA-463 — le unit che l'agent riporta come "attese a riposo": oneshot completate, servizi
    # socket-activated in attesa, unit di sistema disabilitate di serie. È una whitelist di prefissi
    # noti (Debian/Ubuntu, il target dell'agent), confrontata sul nome minuscolo. Conservativa di
    # proposito: copre solo casi certi, così una unit sconosciuta resta "ferma" (visibile) e nessun
    # guasto viene nascosto. Il rischio dichiarato nel ticket è che invecchi con le distribuzioni —
    # al più qualche unit normale resta grigia come prima, mai il contrario.
    SYSTEMD_EXPECTED_INACTIVE_PATTERNS = [
      /\Asystemd-fsck/, /\Asystemd-tmpfiles-/, /\Asystemd-ask-password/, /\Admesg/,
      /\Aconsole-setup/, /\Akeyboard-setup/, /\Aplymouth/, /\Aapt-daily/, /\Aapt-news/,
      /\Aman-db/, /\Alogrotate/, /\Ae2scrub/, /\Afstrim/, /\Adpkg-db-backup/, /\Amotd-news/,
      /\Aplocate/, /\Amlocate/, /\Aupdate-notifier/, /\Aphpsessionclean/, /\Asnapd\./,
      /\Agetty@/, /\Aserial-getty@/, /\Arescue/, /\Aemergency/
    ].freeze

    # Una unit ferma è "attesa" (a riposo per costruzione) se ha completato pulita (substate `exited`,
    # oneshot) o se il nome è fra quelli notoriamente inattivi. Tutto il resto è "fermo" e resta in vista.
    def server_systemd_expected_inactive?(service)
      return true if service["sub"].to_s == "exited"

      name = service["name"].to_s.downcase
      SYSTEMD_EXPECTED_INACTIVE_PATTERNS.any? { |pattern| pattern.match?(name) }
    end

    # Categoria di una riga nell'elenco completo systemd: guida colore, opacità ed etichetta. Le unit
    # ferme "a riposo" (:idle) non hanno lo stesso peso visivo di quelle ferme in modo anomalo (:stopped).
    def server_systemd_kind(service)
      case service["state"].to_s
      when "failed" then :failed
      when "active" then :active
      when "activating", "deactivating", "reloading" then :transitioning
      else server_systemd_expected_inactive?(service) ? :idle : :stopped
      end
    end

    # Nota in chiaro accanto a una unit FERMA ("a riposo" / "fermo"): distingue a parole il caso normale
    # da quello che un'occhiata la merita. nil per le unit attive, in errore o in transizione.
    def server_systemd_note(service)
      case server_systemd_kind(service)
      when :idle then t("member.servers.show.systemd_rest.idle")
      when :stopped then t("member.servers.show.systemd_rest.stopped")
      end
    end
  end
end
