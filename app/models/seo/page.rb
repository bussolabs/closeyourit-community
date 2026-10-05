# frozen_string_literal: true

module Seo
  # L'ultimo stato conosciuto di una URL: cosa ha risposto, cosa dichiara, com'è fatta dentro.
  # Una riga per URL, riscritta a ogni giro — la storia non sta qui (vedi il commento sulla
  # migrazione: cento pagine al giorno diventerebbero milioni di righe che nessuno leggerà).
  #
  # È la materia prima dei rilievi e, insieme, la risposta alla domanda che viene sempre dopo:
  # "sì, ma quella pagina com'era messa?".
  class Page < ApplicationRecord
    self.table_name = "seo_pages"

    belongs_to :site, class_name: "Seo::Site", inverse_of: :pages
    # I rilievi puntano alla pagina, ma non muoiono con lei: se la pagina viene potata perché non
    # si vede da mesi, il rilievo resta con la sua prova dentro `evidence` (FK on_delete: :nullify).
    has_many :issues, class_name: "Seo::Issue", foreign_key: :page_id, inverse_of: :page,
             dependent: :nullify

    validates :url, presence: true, uniqueness: { scope: :site_id }
    validates :first_seen_at, :last_seen_at, presence: true

    scope :ordered, -> { order(:path) }
    scope :recent, -> { order(last_seen_at: :desc) }
    scope :seen_since, ->(instant) { where(last_seen_at: instant..) }
    scope :indexable, -> { where(status_code: 200).where.not("robots_directives ILIKE '%noindex%'") }

    # La pagina risponde davvero, senza rimbalzi? È la domanda che precede ogni altra: su una 404
    # non ha senso lamentarsi del title.
    def ok? = status_code == 200

    def redirected? = redirect_chain.present?

    def h1 = h1s.first

    def missing_h1? = h1s.empty?

    def multiple_h1? = h1s.size > 1

    def noindex? = robots_directives.to_s.downcase.include?("noindex")

    def display_url = path.presence || url
  end
end
