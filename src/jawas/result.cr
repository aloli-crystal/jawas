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

  # Résultat de l'envoi vers une destination `[[remote]]`.
  #
  # `offered` : sauvegardes proposées (fichiers et liens) ; `sent` :
  # fichiers transmis ; `linked` : liens physiques recréés à distance
  # sans transfert ; `present` : déjà présentes à distance.
  class UploadResult
    include JSON::Serializable

    getter remote : String
    getter type : String
    getter destination : String
    getter? applied : Bool
    property offered = 0
    property offered_bytes = 0_i64
    property sent = 0
    property linked = 0
    property present = 0
    property bytes = 0_i64
    property seconds = 0.0
    getter failures = [] of String
    property error : String?

    def initialize(@remote, @type, @destination, @applied)
    end

    def ok? : Bool
      @error.nil? && @failures.empty?
    end
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
    getter uploads = [] of UploadResult

    def initialize(@started_at : Time, @applied : Bool)
    end

    def ok? : Bool
      @errors.empty? && @dumps.all?(&.ok?) && @uploads.all?(&.ok?)
    end

    def total_size : Int64
      @dumps.sum(&.size)
    end
  end
end
