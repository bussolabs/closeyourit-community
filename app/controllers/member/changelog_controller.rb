# frozen_string_literal: true

module Member
  # Pagina "Novità": storico completo del changelog (dal CHANGELOG.md del progetto).
  # Non dipende dall'organizzazione — è generale, ma vive nell'area autenticata.
  #
  # CYRA-445 — si consulta invece di scorrerla: filtro per area e per tipo di modifica, ricerca
  # dentro il testo delle voci e versioni a pagine. Il filtro lavora su dati in memoria (il
  # CHANGELOG.md parsato e messo in cache), quindi niente scope ActiveRecord: `Changelog::Filter`
  # riduce le release e `Pagination.from_array` le impagina.
  class ChangelogController < Member::BaseController
    permission_not_required "Le novità del prodotto: stesso testo per tutti, nessun dato dell'organizzazione da " \
                            "proteggere."

    # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
    remembers_filters :area, :kind, :q, only: :show

    def show
      @areas = Changelog::Areas.options
      @area = Changelog::Areas.known(params[:area])
      @kind = Changelog::Filter.kinds(params[:kind])
      @query = params[:q].to_s.strip

      filtered = Changelog::Filter.call(Changelog.releases, area: @area, kind: @kind, query: @query)
      @entries_count = filtered.sum { |release| release.sections.sum { |section| section[:items].size } }
      @pagination = Pagination.from_array(filtered, page: params[:page],
                                                    per: params[:per].presence || Changelog::Constants::PER_PAGE)
      @releases = @pagination.records
      @latest = Changelog.current
    end

    private

    # Un filtro acceso cambia cosa dire quando non resta niente: «nessuna versione» (il changelog è
    # vuoto) e «nessuna novità con questi filtri» sono due cose diverse per chi guarda.
    def filtering? = @area.any? || @kind.any? || @query.present?
    helper_method :filtering?
  end
end
