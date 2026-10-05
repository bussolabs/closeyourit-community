# frozen_string_literal: true

module Projects
  module Tokens
    module Notifications
      # Snapshot umano (title/body/url) dell'avviso di scadenza di una credenziale di ingest
      # (CYRA-716). MAI il segreto né il suo prefisso: solo nome della credenziale, progetto,
      # ambiente e giorni. Lo snapshot resta leggibile anche se il token viene poi revocato o
      # rinominato, come per gli altri domini.
      Content = Data.define(:title, :body, :url) do
        def self.for(token:, at: Time.current)
          new(
            title: title_for(token, at: at),
            body: body_for(token, at: at),
            url: Rails.application.routes.url_helpers.member_project_tokens_path(token.project)
          )
        end

        # Due titoli, non uno solo con dentro i giorni: «sta per scadere» su una credenziale già morta
        # sarebbe una bugia, e il titolo è l'unica riga che si legge nella lista delle notifiche.
        def self.title_for(token, at: Time.current)
          key = token.expiry_status(at: at) == :expired ? "expired_title" : "title"
          I18n.t("projects.tokens.notifications.content.#{key}",
                 name: token.name, project: token.project.name, environment: token.environment.label)
        end

        # Stessa formula e stesse parole della colonna "Scadenza" nella pagina delle credenziali
        # (member.tokens.expiry.*): un posto solo per la frase, così avviso e pagina non si
        # contraddicono su quanti giorni mancano.
        def self.body_for(token, at: Time.current)
          days = token.days_until_expiry(at: at)
          if token.expiry_status(at: at) == :expired
            I18n.t("member.tokens.expiry.expired_days", count: days.abs)
          else
            I18n.t("member.tokens.expiry.due_in_days", count: days)
          end
        end
      end
    end
  end
end
