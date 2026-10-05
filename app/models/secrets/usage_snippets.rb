# frozen_string_literal: true

module Secrets
  # Punto UNICO in cui vivono i comandi CLI `cyi` mostrati nel Vault dalla sezione «Usa questo segreto»
  # (CYRA-401). Un solo posto per non duplicarli per pagina: se la CLI cambia, si aggiorna qui e le
  # quattro pagine dei segreti si allineano da sole. Interpola SOLO nome progetto e ambiente — mai il
  # valore di un secret (`SecretUsageComponent` non ne dispone nemmeno). I comandi headless (build/server)
  # si autenticano con il token di un account di servizio via env `CLOSEYOURIT_TOKEN`.
  class UsageSnippets
    KINDS = %i[project personal shared].freeze

    # Segnaposto stile terminale (angle brackets): universali, non si traducono. Compilati con i valori
    # reali quando il contesto li conosce (progetto di progetto → key; ambiente → code).
    PROJECT_PLACEHOLDER = "<project>"
    ENVIRONMENT_PLACEHOLDER = "<environment>"
    COMMAND_PLACEHOLDER = "<command>"
    TOKEN_PLACEHOLDER = "<token>"

    attr_reader :kind, :project, :environment

    def initialize(kind:, project: nil, environment: nil)
      @kind = kind.to_sym
      raise ArgumentError, "kind sconosciuto: #{@kind}" unless KINDS.include?(@kind)

      @project = project.to_s.presence || PROJECT_PLACEHOLDER
      @environment = environment.to_s.presence || ENVIRONMENT_PLACEHOLDER
    end

    def personal?
      kind == :personal
    end

    # Sul computer di chi sviluppa: il login è già stato fatto, i secret sono iniettati senza toccare il disco.
    def local
      if personal?
        [ "cyi personal run -- #{COMMAND_PLACEHOLDER}" ]
      else
        [ "cyi run -p #{project} -e #{environment} -- #{COMMAND_PLACEHOLDER}" ]
      end
    end

    # Alternativa direnv per i soli segreti personali: iniezione automatica entrando nella cartella (.envrc).
    def local_direnv
      personal? ? [ "use_cyi_personal" ] : nil
    end

    # Variante dedicata a GitHub Actions: spinge i valori sui secret del repo, poi il workflow li usa nativi.
    # I personali non si sincronizzano su un repo → nessuna variante GitHub.
    def ci_github
      return nil if personal?

      [ "cyi secrets sync -p #{project}" ]
    end

    # Altri sistemi di build (runner generici): token headless in env, poi lo stesso comando del computer.
    def ci_generic
      with_token(local)
    end

    # Sul server: identico agli altri sistemi headless — token in env e `cyi run`/`cyi personal run`.
    def server
      with_token(local)
    end

    private

    def with_token(lines)
      [ "export CLOSEYOURIT_TOKEN=#{TOKEN_PLACEHOLDER}", *lines ]
    end
  end
end
