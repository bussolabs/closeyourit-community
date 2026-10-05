# frozen_string_literal: true

module Member
  # Preferenze personali dell'utente (pagina + update). Tutti i ruoli gestiscono le PROPRIE:
  # - platform_codes: piattaforme che l'utente usa (globali, pre-selezione nei nuovi ticket);
  # - projects_view: modalità lista progetti (cards/table);
  # - locale: lingua dell'interfaccia (en/it) — applicata da Member::BaseController#switch_locale.
  # - theme: light, dark or system — applied by the member layout on <html> (DESIGN.md A32).
  class PreferencesController < Member::BaseController
    permission_not_required "Preferenze personali: ognuno gestisce le proprie, qualunque sia il suo ruolo."

    def show
      # simplecov:disable Member::BaseController#require_organization garantisce Current.organization presente
      # nell'area member → il ramo `: []` (org assente) è difesa irraggiungibile.
      @platforms = Current.organization ? Current.organization.platforms.active.ordered.to_a : []
      # simplecov:enable
    end

    def update
      Current.account.update(platform_codes: clean_codes) if params.key?(:platform_codes)
      view = params[:projects_view]
      Current.account.update(projects_view: view) if Projects::Constants::VIEWS.include?(view)
      locale = params[:locale]
      Current.account.update(locale: locale) if App::Constants::LOCALES.include?(locale)
      theme = params[:theme]
      Current.account.update(theme: theme) if Accounts::Constants::THEMES.include?(theme)
      # The preferences page (one form, every preference) comes back with a notice; the single
      # switches elsewhere (footer language, projects view) go back where they were.
      if params.key?(:platform_codes) || params[:preferences_form].present?
        redirect_to member_preferences_path, notice: t("member.preferences.saved")
      else
        redirect_back fallback_location: member_projects_path
      end
    end

    private

    # Codici puliti: stringhe minuscole, niente blank, deduplicati. L'hidden platform_codes[]=""
    # nel form permette di azzerare la selezione (un multi-select vuoto non invierebbe nulla).
    def clean_codes
      Array(params[:platform_codes]).map { |code| code.to_s.strip.downcase }.reject(&:blank?).uniq
    end
  end
end
