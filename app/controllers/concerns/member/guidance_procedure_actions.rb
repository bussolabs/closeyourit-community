# frozen_string_literal: true

module Member
  # Azioni CRUD di Guidance::Procedure condivise tra i tre livelli (org/gruppo/progetto). Gemello di
  # Member::GuidanceReferenceActions: stessa struttura, param propri della procedura (content +
  # application_mode/merge_strategy). Ogni controller flat implementa `guidance_owner`,
  # `guidance_home_path`, `guidance_collection_url`, `guidance_member_url`, `guidance_level`,
  # `guidance_scope_name` e i before_action di gate/scope.
  module GuidanceProcedureActions
    def new
      @procedure = guidance_procedures.new(enabled: true, application_mode: :inherit, merge_strategy: :override)
      @form_url = guidance_collection_url
      render_procedure_form
    end

    def create
      @procedure = guidance_procedures.new(guidance_procedure_params)
      @procedure.organization = Current.organization
      @procedure.created_by = Current.account
      if @procedure.save
        redirect_to guidance_home_path, notice: t("member.guidance.procedure.created")
      else
        @errors = @procedure.errors.to_hash
        @form_url = guidance_collection_url
        render_procedure_form(:unprocessable_content)
      end
    end

    def edit
      @form_url = guidance_member_url(@procedure)
      render_procedure_form
    end

    def update
      if @procedure.update(guidance_procedure_params)
        redirect_to guidance_home_path, notice: t("member.guidance.procedure.updated")
      else
        @errors = @procedure.errors.to_hash
        @form_url = guidance_member_url(@procedure)
        render_procedure_form(:unprocessable_content)
      end
    end

    def destroy
      @procedure.destroy
      redirect_to guidance_home_path, notice: t("member.guidance.procedure.deleted")
    end

    def reorder
      Guidance::Reorder.call(collection: guidance_procedures, ordered_ids: params[:ordered_ids])
      head :ok
    end

    private

    def guidance_procedures = guidance_owner.guidance_procedures

    # Anti-BOLA: la procedura vive dentro la collection dell'owner scoped → un id estraneo dà 404.
    def set_guidance_procedure
      @procedure = guidance_procedures.find(params[:id])
    end

    def guidance_procedure_params
      params.permit(:key, :content, :application_mode, :merge_strategy, :enabled, :position)
    end

    # Il form è uno solo per i tre livelli: senza queste due (CYRA-576) non dichiarava a quale livello
    # si stesse scrivendo, e l'unico indizio era l'indirizzo della pagina.
    def render_procedure_form(status = :ok)
      @back_url = guidance_home_path
      @guidance_level = guidance_level
      @guidance_scope_name = guidance_scope_name
      render template: "member/guidance/procedure_form", status: status
    end
  end
end
