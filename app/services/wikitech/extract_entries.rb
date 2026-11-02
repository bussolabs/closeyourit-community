# frozen_string_literal: true

module Wikitech
  # Reads a note with the AI and returns one item per project it presents, keeping only the
  # technical, relevant part (CYRA-1129). An empty list means the note had nothing technical.
  class ExtractEntries < ApplicationService
    Item = Data.define(:name, :repo_url, :summary, :facts, :categories, :links, :quote)

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You read a note about technology: the transcript of a short video, its caption, or text from
      the web pages of the projects it mentions. Return one item for every software project, tool,
      library or service that the note actually presents.

      Keep ONLY technical and relevant information: what the project is for, how it works, language
      and stack, license, how to install or run it, comparisons with other tools, limits and warnings.
      Drop everything else: greetings, jokes, calls to follow or like, "link in bio", sponsors that
      are not about the project, comments from users, hashtags, emoji, music, opinions without content.

      A tool only named along the way (a dependency, an integration, something used to build or run
      the presented project) is not an item: it goes in the facts of the project that uses it.

      Never invent projects, addresses or facts that are not in the note. When the note has nothing
      technical, return an empty list.

      When the video part and a project page disagree on a fact (a version, a number, a platform),
      trust the project page and leave out the claim from the video.

      For each item:
      - `name`: the project name as written by its authors.
      - `repo_url`: its GitHub repository address only if it appears in the note, otherwise empty.
      - `summary`: what it is for, in one plain sentence of at most 80 characters.
      - `facts`: short technical facts stated in the note, one per entry.
      - `categories`: two or three short lowercase topics (e.g. "game dev", "self-hosted", "ai").
      - `links`: other addresses of the project found in the note (site, docs).
      - `quote`: the most technical sentence the note says about it, copied as it is.
    PROMPT

    SCHEMA = {
      type: "object",
      properties: {
        items: {
          type: "array",
          items: {
            type: "object",
            properties: {
              name: { type: "string" }, repo_url: { type: "string" }, summary: { type: "string" },
              facts: { type: "array", items: { type: "string" } },
              categories: { type: "array", items: { type: "string" } },
              links: { type: "array", items: { type: "string" } },
              quote: { type: "string" }
            },
            required: %w[name summary]
          }
        }
      },
      required: %w[items]
    }.freeze

    def initialize(note:, client: nil)
      @note = note
      @client = client
    end

    def call
      args = Ai::Structured.call(client: @client || Ai::Llm::Client.new, system: SYSTEM_PROMPT,
                                 user: user_text, schema: SCHEMA,
                                 max_output_tokens: Wikitech::Constants::EXTRACT_MAX_OUTPUT_TOKENS)
      Result.ok(Array(args["items"]).filter_map { |raw| item(raw) })
    rescue Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    end

    private

    def user_text
      [ ("Source: #{@note.source_label}" if @note.source_label),
        ("Links found in the content: #{@note.links.join(' ')}" if @note.links.any?),
        "Note:\n#{@note.body}" ].compact.join("\n\n")
    end

    def item(raw)
      name = raw["name"].to_s.squish.first(255)
      return nil if name.blank?

      Item.new(name: name, repo_url: Wikitech::RepoUrl.normalize(raw["repo_url"]),
               summary: short_summary(raw["summary"]),
               facts: texts(raw["facts"], Wikitech::Constants::FACT_MAX_CHARS),
               categories: texts(raw["categories"], 40).map(&:downcase).uniq,
               links: Array(raw["links"]).map { |link| link.to_s.strip }.grep(%r{\Ahttps?://}).uniq,
               quote: raw["quote"].to_s.squish.first(Wikitech::Constants::QUOTE_MAX_CHARS).presence)
    end

    # The model is asked for 80 characters; a longer answer is cut at the last word that fits.
    def short_summary(raw)
      text = raw.to_s.squish
      max = Wikitech::Constants::SUMMARY_MAX_CHARS
      return text.presence if text.length <= max

      "#{text.first(max - 1).sub(/\s+\S*\z/, '')}…"
    end

    def texts(values, max) = Array(values).map { |value| value.to_s.squish.first(max) }.compact_blank.uniq
  end
end
