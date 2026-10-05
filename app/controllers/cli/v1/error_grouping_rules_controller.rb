# frozen_string_literal: true

module Cli
  module V1
    # Regole di raggruppamento personalizzate di un progetto (CYRA-153): CRUD per-progetto. La lettura
    # (index) è gata dalla sola visibilità del progetto, come per gli error_groups; create/update/destroy
    # richiedono errors.grouping.manage (configurano l'ingest). Progetto fuori scope → R404 (anti-BOLA).
    class ErrorGroupingRulesController < Cli::V1::BaseController
      before_action :set_project!
      before_action -> { require_permission!("errors.grouping.manage", scope: @project) }, only: %i[create update destroy]
      before_action :validate_enums!, only: %i[create update]
      before_action :set_rule, only: %i[update destroy]

      def index
        records, meta = paginate(@project.error_grouping_rules.ordered)
        render_ok(ErrorGroupingRuleSerializer.new(records), meta: meta)
      end

      def create
        rule = @project.error_grouping_rules.new(rule_params)
        if rule.save
          render_created(ErrorGroupingRuleSerializer.new(rule))
        else
          render_rule_error(rule)
        end
      end

      def update
        if @rule.update(rule_params)
          render_ok(ErrorGroupingRuleSerializer.new(@rule))
        else
          render_rule_error(@rule)
        end
      end

      def destroy
        @rule.destroy!
        render_no_content
      end

      private

      def set_rule
        @rule = @project.error_grouping_rules.find(params[:id])
      end

      def rule_params
        params.permit(:field, :operator, :value, :fingerprint_key, :position, :active)
      end

      # field/operator sono enum: assegnare un valore fuori vocabolario (inclusa la stringa vuota)
      # solleverebbe ArgumentError (500) invece di un 422 onesto. Lo intercettiamo PRIMA
      # dell'assegnazione. `key?` e non `present?`: un field="" è presente-ma-vuoto e senza questo
      # controllo scivolerebbe fino all'assegnazione col 500 (il buco che chiudiamo).
      def validate_enums!
        bad = []
        bad << "field" if params.key?(:field) && !Errors::GroupingRule.fields.key?(params[:field].to_s)
        bad << "operator" if params.key?(:operator) && !Errors::GroupingRule.operators.key?(params[:operator].to_s)
        return if bad.empty?

        render_error("R422-ERRGROUPRULE-002", "Valore non ammesso per: #{bad.join(', ')}",
                     status: :unprocessable_content)
      end

      def render_rule_error(rule)
        render_error("R422-ERRGROUPRULE-001", rule.errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: rule.errors.to_hash)
      end
    end
  end
end
