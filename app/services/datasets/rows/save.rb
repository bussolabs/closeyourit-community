# frozen_string_literal: true

module Datasets
  module Rows
    # Crea/aggiorna una riga del dataset: valori scalari nel jsonb (keyed per column code) + celle
    # foto (blob ActiveStorage, sniff Marcel sui byte reali, all-or-nothing come Projects::Documents::
    # Upload). Enforce dei required. purpose=sample (training) o prediction (input di inferenza, fase 5).
    class Save < ApplicationService
      def initialize(dataset:, actor:, values:, photos:, row: nil, purpose: :sample)
        @dataset = dataset
        @actor = actor
        @values = (values || {}).to_h
        @photos = (photos || {}).to_h.reject { |_code, file| file.blank? }
        @row = row
        @purpose = purpose
      end

      def call
        columns = @dataset.columns.ordered.to_a
        errors = validate(columns)
        return invalid(errors) if errors.any?
        return invalid(image: [ :invalid ]) unless @photos.values.all? { |file| allowed?(file) }

        row = persist(columns)
        Result.ok(row)
      rescue ActiveRecord::RecordInvalid => e
        invalid(e.record.errors.to_hash)
      end

      private

      def by_code(columns) = columns.index_by(&:code)

      # Scalari ammessi = solo i code delle colonne NON-foto (result incluso per le righe sample).
      def scalar_values(columns)
        codes = columns.reject(&:kind_photo?).map(&:code)
        @values.slice(*codes).transform_keys(&:to_s)
      end

      def persist(columns)
        ActiveRecord::Base.transaction do
          row = @row || @dataset.rows.new(purpose: @purpose)
          row.cell_values = scalar_values(columns)
          row.save!
          attach_photos(row, by_code(columns))
          row
        end
      end

      # Una cella per (riga, colonna foto): sostituisce il blob esistente col nuovo file.
      def attach_photos(row, columns_by_code)
        @photos.each do |code, file|
          column = columns_by_code[code.to_s]
          next if column.nil? || !column.kind_photo?

          cell = row.cells.find_or_initialize_by(column: column)
          cell.image.attach(file)
          cell.save!
        end
      end

      # Enforce required: scalare non-blank; foto = nuovo file O cella esistente. Result obbligatorio
      # sulle righe sample (è il target di training). Ritorna un hash campo → [codici errore].
      def validate(columns)
        errors = {}
        columns.each do |column|
          next unless required?(column)

          errors[column.code] = [ :blank ] if missing?(column)
        end
        errors
      end

      def required?(column)
        # Su una riga sample TUTTI i target sono obbligatori (sono le etichette del training).
        return true if column.role_target? && @purpose.to_s == "sample"

        column.role_input? && column.required?
      end

      def missing?(column)
        if column.kind_photo?
          @photos[column.code].blank? && !existing_photo?(column)
        else
          @values[column.code].to_s.strip.blank?
        end
      end

      def existing_photo?(column)
        @row.present? && @row.cells.any? { |cell| cell.column_id == column.id && cell.image.attached? }
      end

      # Tipo SNIFFATO da Marcel sui byte reali (non il content-type dichiarato dal client).
      #
      # Il primo controllo è sulla FORMA: dal canale CLI `photos[foto]` è un parametro qualsiasi, e un
      # client che manda un nome di file invece del multipart consegnerebbe una String — che qui
      # esploderebbe su `tempfile` come errore del server invece del 422 che il chiamante sa leggere
      # (CYRA-646, stessa trappola di Projects::Documents::Upload).
      def allowed?(file)
        return false unless file.respond_to?(:tempfile)

        sniffed = Marcel::MimeType.for(file.tempfile, name: file.original_filename, declared_type: file.content_type)
        Datasets::Cell.allowed?(content_type: sniffed, byte_size: file.size)
      end

      def invalid(details)
        Result.err(AppError.new(I18n.t("datasets.errors.row_invalid"), code: "R422-DATASET-003", details: details))
      end
    end
  end
end
