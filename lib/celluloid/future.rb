require 'thread'

module Celluloid
  # Celluloid::Future objects allow methods and blocks to run in the
  # background, their values requested later
  class Future
    # Create a future bound to a given receiver, or with a block to compute
    def initialize(*args, &block)
      @mutex = Mutex.new
      @ready = false
      @result = nil
      @forwards = nil

      if block
        @call = SyncCall.new(self, :call, args)
        Actor::Pool.get { @call.dispatch(block) }
      else
        @call = nil
      end
    end

    # Execute the given method in future context
    def execute(receiver, method, args, block)
      @call = SyncCall.new(self, method, args, block)
      receiver << @call
    end

    # Obtain the value for this Future
    def value
      ready = result = nil

      begin
        @mutex.lock
        raise "no call requested" unless @call

        if @ready
          ready = true
          result = @result
        else
          case @forwards
          when Array
            @forwards << Thread.mailbox
          when NilClass
            @forwards = Thread.mailbox
          else
            @forwards = [@forwards, Thread.mailbox]
          end
        end
      ensure
        @mutex.unlock
      end

      unless ready
        if Celluloid.actor?
          result = Celluloid.receive do |msg|
            msg.is_a?(Future::Result) && msg.future == self
          end
        else
          result = Thread.mailbox.receive do |msg|
            msg.is_a?(Future::Result) && msg.future == self
          end
        end
      end

      result.value
    end
    alias_method :call, :value

    # Signal this future with the given result value
    def signal(value)
      result = Result.new(value, self)

      @mutex.synchronize do
        raise "the future has already happened!" if @ready

        if @forwards
          @forwards.is_a?(Array) ? @forwards.each { |f| f << result } : @forwards << result
        end

        @result = result
        @ready = true
      end
    end
    alias_method :<<, :signal

    # Inspect this Celluloid::Future
    alias_method :inspect, :to_s

    # Wrapper for result values to distinguish them in mailboxes
    class Result
      attr_reader :future

      def initialize(result, future)
        @result, @future = result, future
      end

      def value
        @result.value
      end
    end
  end
end
