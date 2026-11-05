# frozen_string_literal: true

module Vulnerabilities
  # Una dipendenza risolta dentro un manifest: nome, versione esatta, e se il progetto la dichiara
  # (`direct`) o se se la porta dietro. La distinzione conta in triage: una vulnerabilità su una
  # dipendenza diretta si risolve aggiornando quella riga, su una transitiva spesso no.
  #
  # `ecosystem` è ripetuto qui e non solo sul manifest perché la fase container introdurrà pacchetti
  # di sistema (`Debian:12`, `Alpine:v3.x`) che non nascono da un lockfile — la validazione resta
  # quindi di sola presenza, non di inclusione.
  class Package < ApplicationRecord
    self.table_name = "vulnerabilities_packages"

    belongs_to :manifest, class_name: "Vulnerabilities::Manifest", inverse_of: :packages
    has_many :findings, class_name: "Vulnerabilities::Finding", foreign_key: :package_id,
             inverse_of: :package, dependent: :destroy

    validates :name, presence: true, uniqueness: { scope: %i[manifest_id version] }
    validates :version, presence: true
    validates :ecosystem, presence: true

    scope :direct, -> { where(direct: true) }
    scope :ordered, -> { order(:name, :version) }

    def coordinates = "#{name}@#{version}"

    # La chiave con cui OSV identifica il pacchetto in una query batch: due manifest diversi che
    # dichiarano la stessa coppia si risolvono con UNA sola richiesta.
    def osv_key = [ ecosystem, name, version ]
  end
end
