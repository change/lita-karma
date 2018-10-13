 module Lita::Handlers::Karma
  class Term
    include Lita::Handler::Common

    namespace "karma"

    attr_reader :term

    class << self
      def list_best(robot, n = 5)
        list(:zrevrange, robot, n)
      end

      def list_worst(robot, n = 5)
        list(:zrange, robot, n)
      end

      private

      def list(redis_command, robot, n)
        n = 24 if n > 24

        handler = new(robot, '', normalize: false)
        handler.redis.public_send(redis_command, "terms", 0, n, with_scores: true)
      end
    end

    def initialize(robot, term, normalize: true)
      super(robot)
      @term = normalize ? normalize_term(term) : term
      @link_cache = {}
    end

    def check(show_all = true)
      string = "#{self}: #{total_score}"

      scores = show_all ? links_with_scores : links_with_non_zero_scores

      unless scores.empty?
        link_text = scores.map { |term, score| "#{term}: #{score}" }.join(", ")
        string << " (#{own_score}), #{t("linked_to")}: #{link_text}"
      end

      string
    end

    def decrement(user)
      modify(user, -1)
    end

    def delete
      redis.zrem("terms", to_s)
      redis.del("modified:#{self}")
      redis.del("links:#{self}")
      redis.smembers("linked_to:#{self}").each do |key|
        redis.srem("links:#{key}", to_s)
      end
      redis.del("linked_to:#{self}")
    end

    def eql?(other)
      term.eql?(other.term)
    end

    def hash
      term.hash
    end

    def increment(user)
      modify(user, 1)
    end

    def link(other)
      if config.link_karma_threshold
        threshold = config.link_karma_threshold.abs

        if own_score.abs < threshold || other.own_score.abs < threshold
          return threshold
        end
      end

      redis.sadd("links:#{self}", other.to_s) && redis.sadd("linked_to:#{other}", to_s)
    end

    def links
      @links ||= begin
        redis.smembers("links:#{self}").each do |term|
          linked_term = self.class.new(robot, term)
          @link_cache[linked_term.term] = linked_term
        end
      end
    end

    def links_with_scores
      @links_with_scores ||= begin
        {}.tap do |h|
          links.each do |link|
            h[link] = @link_cache[link].own_score
          end
        end
      end
    end

    def links_with_non_zero_scores
      @links_with_non_zero_scores ||= links_with_scores.reject {|k,v| v.zero? }
    end

    def modified
      redis.zrevrange("modified:#{self}", 0, -1, with_scores: true).map do |(user_id, score)|
        [Lita::User.find_by_id(user_id), score.to_i]
      end
    end

    def own_score
      @own_score ||= redis.zscore("terms", term).to_i
    end

    def to_s
      term
    end

    def total_score
      @total_score ||= begin
        links.inject(own_score) do |memo, linked_term|
          memo + @link_cache[linked_term].own_score
        end
      end
    end

    def unlink(other)
      redis.srem("links:#{self}", other.to_s) && redis.srem("linked_to:#{other}", to_s)
    end

    private

    def add_action(user_id, delta)
      return unless decay_enabled?

      Action.create(redis, term, user_id, delta)
    end

    def decay_enabled?
      config.decay && decay_interval > 0
    end

    def decay_interval
      config.decay_interval
    end


    def modify(user, delta)
      ttl = redis.ttl("cooldown:#{user.id}:#{term}")

      if ttl > 0
        t("cooling_down", term: self, ttl: ttl, count: ttl)
      else
        modify!(user, delta)
      end
    end

    def modify!(user, delta)
      user_id = user.id
      redis.zincrby("terms", delta, term)
      redis.zincrby("modified:#{self}", 1, user_id)
      redis.setex("cooldown:#{user_id}:#{self}", config.cooldown, 1) if config.cooldown
      add_action(user_id, delta)
      check(false)
    end

    def normalize_term(term)
      config.term_normalizer.call(term)
    end
  end
end
