# frozen_string_literal: true

module Member
  # Azioni CRUD di Guidance::Reference condivise tra i tre livelli (org/gruppo/progetto): la logica è
  # identica, cambiano solo owner, gate e path — che ogni controller flat fornisce (CYRA-75). Il gate e
  # lo scoping anti-BOLA (`set_scope` → `guidance_owner`) sono before_action DEL CONTROLLER, dichiarati
  # prima di `set_guidance_reference` così l'owner è già risolto. Ogni controller include il concern e
  # implementa: `guidance_owner`, `guidance_home_path`, `guidance_collection_url`, `guidance_member_url`,
  # `guidance_level` e `guidance_scope_name`.
  module GuidanceReferenceActions
    def new
      @reference = guidance_references.new(enabled: true, kind: :repository)
      @form_url = guidance_collection_url
      render_reference_form
    end

    def create
      @reference = guidance_references.new(guidance_reference_params)
      @reference.organization = Current.organization
      @reference.created_by = Current.account
      if @reference.save
        redirect_to guidance_home_path, notice: t("member.guidance.reference.created")
      else
        @errors = @reference.errors.to_hash
        @form_url = guidance_collection_url
        render_reference_form(:unprocessable_content)
      end
    end

    def edit
      @form_url = guidance_member_url(@reference)
      render_reference_form
    end

    def update
      if @reference.update(guidance_reference_params)
        redirect_to guidance_home_path, notice: t("member.guidance.reference.updated")
      else
        @errors = @reference.errors.to_hash
        @form_url = guidance_member_url(@reference)
        render_reference_form(:unprocessable_content)
      end
    end

    def destroy
      @reference.destroy
      redirect_to guidance_home_path, notice: t("member.guidance.reference.deleted")
    end

    def reorder
      Guidance::Reorder.call(collection: guidance_references, ordered_ids: params[:ordered_ids])
      head :ok
    end

    private

    def guidance_references = guidance_owner.guidance_references

    # Anti-BOLA: la reference vive dentro la collection dell'owner scoped → un id estraneo dà 404.
    def set_guidance_reference
      @reference = guidance_references.find(params[:id])
    end

    def guidance_reference_params
      params.permit(:key, :kind, :location, :instructions, :required, :enabled, :position)
    end

    # Il form è uno solo per i tre livelli: senza queste due (CYRA-576) non dichiarava a quale livello
    # si stesse scrivendo, e l'unico indizio era l'indirizzo della pagina.
    def render_reference_form(status = :ok)
      @back_url = guidance_home_path
      @guidance_level = guidance_level
      @guidance_scope_name = guidance_scope_name
      render template: "member/guidance/reference_form", status: status
    end
  end
end
