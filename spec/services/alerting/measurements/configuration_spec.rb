# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Measurements::Configuration do
  let(:series) { Measurements::Series.new(metric_type: "gauge") }
  let(:configuration) { { "version" => 1, "statistic" => "last", "comparison" => "gt", "threshold" => "0", "window_seconds" => 60 } }

  it "validates exact window boundaries and all supported comparisons" do
    %w[gt gte lt lte].each do |comparison|
      [ 60, 86_400 ].each do |window|
        value = configuration.merge("comparison" => comparison, "window_seconds" => window)
        expect(described_class.validate!(value, series: series)).to eq(value)
      end
    end
    [ 59, 86_401, "60", 60.5 ].each do |window|
      expect { described_class.validate!(configuration.merge("window_seconds" => window), series: series) }.to raise_error(described_class::Invalid)
    end
  end

  it "rejects unsupported shapes, versions, series, statistics and operators" do
    [ nil, {}, configuration.merge("unexpected" => true), configuration.merge("version" => 2),
      configuration.merge("statistic" => "percentile"), configuration.merge("comparison" => "eq"),
      configuration.merge("threshold" => "0" * 4097) ].each do |value|
      expect { described_class.validate!(value, series: series) }.to raise_error(described_class::Invalid)
    end
    expect { described_class.validate!(configuration, series: nil) }.to raise_error(described_class::Invalid)
  end

  it "permits quantiles only for histogram percentiles" do
    value = configuration.merge("statistic" => "percentile", "quantile" => "0.95")
    histogram = Measurements::Series.new(metric_type: "histogram")
    expect(described_class.validate!(value, series: histogram)).to eq(value)
    expect { described_class.validate!(value.merge("quantile" => "1.1"), series: histogram) }.to raise_error(described_class::Invalid, "Invalid quantile")
    expect { described_class.validate!(configuration.merge("quantile" => "0.95"), series: series) }.to raise_error(described_class::Invalid, "Quantile applies only to percentiles")
  end

  it "keeps thresholds decimal and finite without silently casting malformed input" do
    [ 1, "NaN", "Infinity", "1e3", " 1", "1\n", "1" * 65 ].each do |threshold|
      expect { described_class.decimal(threshold) }.to raise_error(described_class::Invalid)
    end
    expect(described_class.decimal("-0.0001")).to eq(BigDecimal("-0.0001"))
  end
end
