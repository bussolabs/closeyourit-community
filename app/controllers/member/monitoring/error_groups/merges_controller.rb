# frozen_string_literal: true

module Member
  module Monitoring
    module ErrorGroups
      # CYRA-800 — l'unione di due o più gruppi di errore, in due passi: la conferma che mostra cosa
      # sparisce, e la fusione vera. Un file suo perché è l'unica cosa qui dentro che non si annulla.
      #
      # Gate errors.destroy (CYRA-192), non errors.triage: fondere distrugge dati, smistare no.
      class MergesController < Member::BaseController
        # CYRA-728 — la pagina che mostra cosa succederebbe fondendo la selezione non tocca niente: è
        # POST perché la selezione è lunga e non ci sta in un indirizzo, ed è essa stessa la
        # schermata di conferma. È il passo dopo a pretenderla.
        confirmation_not_required "mostra soltanto l'anteprima della fusione, non fonde niente",
                                  only: :preview

        # CYRA-192 — passo 1: la conferma. Non esegue niente, rende la pagina che dice COSA sparisce
        # (titolo, punto del codice, occorrenze, periodo) e fa scegliere quale gruppo resta. Tutti i
        # controlli si rifanno nel passo 2: questa non è un gate, è una lettura.
        def preview
          @groups = mergeable_selection(params[:ids])
          return if performed?

          # Il primario PROPOSTO è quello con più occorrenze: è quasi sempre il gruppo "storico" su
          # cui si sono accumulati eventi e collegamenti. Resta una proposta — la sceglie chi conferma.
          @primary = @groups.max_by(&:events_count)
        end

        # CYRA-192 — passo 2: la fusione vera, IRREVERSIBILE. Gli id vanno al service GREZZI: è lui a
        # risolverli tutti-o-nessuno entro il progetto del primario. Filtrarli qui fonderebbe quelli
        # validi ignorando gli altri in silenzio, che su un'operazione che non si annulla è il peggio.
        def create
          if params[:primary_id].blank?
            nothing_to_authorize!
            return redirect_to(member_monitoring_error_groups_path,
                               alert: t("member.monitoring.merge.no_primary"))
          end

          primary = visible.error_groups.find(params[:primary_id])
          # Il gate è inline e non un before_action perché il progetto si conosce solo dopo aver
          # risolto il primario: `require_permission!` REDIRIGE (non solleva), quindi senza questo
          # `performed?` l'azione proseguirebbe fino a fondere davvero e poi fallirebbe sul secondo
          # render — con la fusione già fatta.
          require_permission!("errors.destroy", scope: primary.project)
          return if performed?

          merge!(primary)
        end

        private

        def merge!(primary)
          result = ::Errors::Merge.call(primary:, source_ids: params[:ids])
          if result.err?
            return redirect_to member_monitoring_error_groups_path, alert: result.error.message
          end

          # La lista ha perso righe e i contatori del primario sono cambiati: un replace della sola
          # riga lascerebbe in pagina quelle dei gruppi che non esistono più. Il progetto è uno solo e
          # va dichiarato, o chi sta guardando quel progetto resterebbe con le righe sparite (CYRA-822).
          ::Errors::Broadcast.refresh_list(current_organization, projects: [ primary.project ])
          redirect_to member_monitoring_error_group_path(result.value),
                      notice: t("member.monitoring.merge.done", count: absorbed_count(primary))
        end

        # Quanti gruppi sono stati assorbiti: la selezione meno il primario, che resta.
        def absorbed_count(primary)
          Array(params[:ids]).map(&:to_s).uniq.count { |id| id != primary.id.to_s }
        end

        # CYRA-192 — i gruppi selezionati, validati come li validerebbe il service: o sono tutti
        # fondibili o non si va avanti. Un id scartato in silenzio qui produrrebbe una conferma che
        # promette una cosa e ne fa un'altra. Rende il redirect e torna nil quando la selezione non
        # regge (il chiamante controlla `performed?`).
        def mergeable_selection(ids)
          wanted = Array(ids).reject(&:blank?).map(&:to_s).uniq
          groups = visible.error_groups.includes(:project).where(id: wanted).to_a
          return merge_refused(:too_few) if wanted.size < 2
          # Meno di quelli chiesti = id di un'altra org, di un progetto non assegnato o una lista
          # vecchia dopo una fusione già fatta: in tutti i casi si ferma tutto (anti-BOLA compreso).
          return merge_refused(:unknown) if groups.size != wanted.size
          # Il fingerprint è unico PER PROGETTO e le occorrenze denormalizzano project_id: fondere fra
          # progetti sposterebbe i dati di un tenant sotto un altro.
          return merge_refused(:cross_project) if groups.map(&:project_id).uniq.size > 1

          require_permission!("errors.destroy", scope: groups.first.project)
          groups
        end

        def merge_refused(reason)
          nothing_to_authorize!
          redirect_to member_monitoring_error_groups_path, alert: t("member.monitoring.merge.refused_#{reason}")
          nil
        end
      end
    end
  end
end
