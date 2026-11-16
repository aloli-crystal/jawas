module Jawas
  # Les trois niveaux de rotation hérités d'automysqlbackup.
  enum Period
    Daily
    Weekly
    Monthly

    def dirname : String
      to_s.downcase
    end

    def self.parse(name : String) : Period
      parse?(name) || raise ConfigError.new("période inconnue « #{name} » (daily, weekly, monthly)")
    end
  end

  # Décide dans quelles périodes une sauvegarde prise à `time` doit
  # figurer.
  #
  # Contrairement à automysqlbackup (un seul dossier par exécution),
  # chaque exécution alimente *toujours* `daily` ; les jours concernés,
  # le même fichier est en plus lié (hardlink) dans `weekly` et/ou
  # `monthly`. La série quotidienne n'a donc jamais de trou et le coût
  # disque des copies hebdomadaires/mensuelles est nul.
  module Calendar
    # `weekly_day` : 1 = lundi … 7 = dimanche (ISO 8601), 0 = désactivé.
    # `monthly_day` : 1…31, 0 = désactivé. Un jour supérieur à la
    # longueur du mois vise le dernier jour du mois (31 → 30 avril,
    # 28 ou 29 février).
    def self.periods_for(time : Time, weekly_day : Int32, monthly_day : Int32) : Array(Period)
      periods = [Period::Daily]
      periods << Period::Weekly if weekly_day > 0 && time.day_of_week.value == weekly_day
      if monthly_day > 0
        target = Math.min(monthly_day, Time.days_in_month(time.year, time.month))
        periods << Period::Monthly if time.day == target
      end
      periods
    end
  end
end
