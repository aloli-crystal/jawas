require "json"

module Jawas
  # Résultat de la sauvegarde d'une base.
  class DumpResult
    include JSON::Serializable

    getter source : String
    getter database : String
    getter periods : Array(String)
    getter path : String?
    getter size : Int64
    getter sha256 : String?
    getter seconds : Float64
    getter error : String?

    def initialize(@source, @database, @periods, @path = nil, @size = 0_i64, @sha256 = nil,
                   @seconds = 0.0, @error = nil)
    end

    def ok? : Bool
      @error.nil?
    end
  end

  # Fichier supprimé (ou qui le serait, en dry-run) par la rotation.
  record PrunedFile, path : String, period : String, age_days : Int32 do
    include JSON::Serializable
  end

  # Rapport complet d'une exécution, sérialisé dans `last-run.json`.
  class Report
    include JSON::Serializable

    getter version : String = VERSION
    getter started_at : Time
    property finished_at : Time?
    getter? applied : Bool
    getter dumps = [] of DumpResult
    getter pruned = [] of PrunedFile
    getter errors = [] of String

    def initialize(@started_at : Time, @applied : Bool)
    end

    def ok? : Bool
      @errors.empty? && @dumps.all?(&.ok?)
    end

    def total_size : Int64
      @dumps.sum(&.size)
    end
  end
end
