# frozen_string_literal: true

module Member
  module Monitoring
    module ErrorGroups
      # CYRA-800 — lo smistamento di un gruppo di errori: risolvi, ignora, riapri, il verdetto chiesto
      # all'AI, e le stesse tre mosse su più gruppi insieme. Sta lontano dalla lista e dalla scheda
      # perché cambia per motivi suoi. Gate errors.triage sul progetto del gruppo (ErrorGroupScoping);
      # il bulk lo rifà progetto per progetto, perché la selezione può attraversarne più d'uno.
      class TriagesController < Member::BaseController
        include ErrorGroupScoping

        before_action :set_group, only: %i[resolve ignore reopen triage_ai]
        before_action :require_triage_role, only: %i[resolve ignore reopen triage_ai]

        # CYRA-192: la chiusura porta con sé la spiegazione — causa (cosa lo provocava) e rimedio
        # (cosa è stato fatto). Entrambe opzionali, e il service non cancella quella scritta la volta
        # prima. Su ignore/reopen non si passano: la riapertura le azzera di proposito.
        def resolve = triage("resolve", cause: params[:cause], fix: params[:fix])
        def ignore  = triage("ignore")
        def reopen  = triage("reopen")

        # CYRA-45: smistamento a più gruppi dalla lista. Dopo un rilascio rumoroso si selezionano N
        # gruppi e si marcano in un colpo. Anti-BOLA a due strati: id VISIBILI, poi solo quelli su
        # cui ho errors.triage per il loro progetto. Broadcast batch: un solo page-refresh org.
        def bulk_triage
          permitted_ids = triageable_error_group_ids(params[:ids])
          result = ::Errors::BulkTriage.call(
            scope: visible.error_groups, ids: permitted_ids, action: params[:bulk_action]
          )
          return redirect_to member_monitoring_error_groups_path, alert: t("member.monitoring.bulk.invalid") if result.err?

          # Il bulk può attraversare più progetti: si dichiarano tutti quelli toccati, o le liste
          # filtrate su uno di essi non si accorgerebbero dello smistamento (CYRA-822).
          if result.value.any?
            ::Errors::Broadcast.refresh_list(current_organization, projects: result.value.map(&:project))
          end
          redirect_to member_monitoring_error_groups_path,
                      notice: t("member.monitoring.bulk.done", count: result.value.size)
        end

        # Verdetto AI on-demand, ASINCRONO: accoda Ai::RunJob (202 + request_id) — il polling del
        # gateway (~30s) non occupa un thread Puma. La UI polla /member/ai/requests/:id.
        # Vedi Errors::TriageWithAi. Gateway giù → richiesta failed, i pulsanti nativi restano usabili.
        def triage_ai
          enqueue_ai_request!(kind: "error_triage", args: { group_id: @group.id })
        end

        private

        def triage(action, **notes)
          ::Errors::Triage.call(group: @group, action: action, **notes)
          # Realtime: lo stato è cambiato → ri-broadcasta riga + stats sullo stream errors dell'org.
          # Il broadcast vive qui, nel canale Member, e NON in Errors::Triage perché quel service è
          # condiviso con il canale API.
          ::Errors::Broadcast.group(@group)
          redirect_to member_monitoring_error_group_path(@group), notice: t("member.monitoring.notice_#{action}")
        end

        # Id dei gruppi selezionati su cui l'attore può davvero smistare: visibili E con errors.triage
        # sul rispettivo progetto. Un id non visibile o senza permesso viene scartato (no 403
        # sull'intera azione: si applica il possibile). can? è cache-ato per progetto.
        def triageable_error_group_ids(ids)
          visible.error_groups.where(id: Array(ids).reject(&:blank?)).includes(:project)
                                      .select { |group| can?("errors.triage", scope: group.project) }
                                      .map(&:id)
        end
      end
    end
  end
end
