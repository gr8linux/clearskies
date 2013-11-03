require 'ffi'
require 'socket'

# See https://defuse.ca/gnutls-psk-client-server-example.htm

module GnuTLS
  extend FFI::Library

  loaded = false
  %w{gnutls gnutls.so.26 gnutls.so.28}.each do |lib|
    begin
      ffi_lib lib
      loaded = true
      break
    rescue LoadError
    end
  end
  raise "Cannot load GNUTLS" unless loaded

  def self.tls_function(name, *args)
    attach_function name, :"gnutls_#{name}", *args
  end

  # types
  enum :credentials_type, [:CRD_CERTIFICATE, 1,
                           :CRD_ANON,
                           :CRD_SRP,
                           :CRD_PSK,
                           :CRD_IA]
  enum :psk_key_type, [
    :PSK_KEY_RAW,
    :PSK_KEY_HEX
  ]

  # structs
  class Datum < FFI::Struct
    layout :data, :pointer,
           :size, :uint
  end

  # callbacks
  callback :log_function, [:int, :string], :void
  callback :push_function, [:pointer, :pointer, :size_t], :size_t
  callback :pull_function, [:pointer, :pointer, :size_t], :size_t
  callback :psk_creds_function, [:pointer, :string, :pointer], :int

  def self.tls_function name, *args
    attach_function name, "gnutls_#{name}".to_sym, *args
  end

  # global functions
  tls_function :global_init, [], :void
  tls_function :global_set_log_level, [ :int ], :void
  tls_function :global_set_log_function, [ :log_function ], :void

  # functions
  attach_function :gnutls_init, [:pointer, :int], :int
  tls_function :deinit, [:pointer], :void
  tls_function :error_is_fatal, [:int], :int
  tls_function :priority_set_direct, [:pointer, :string, :pointer], :int
  tls_function :credentials_set, [:pointer, :credentials_type, :pointer], :int
  tls_function :psk_allocate_client_credentials, [:pointer], :int
  tls_function :psk_allocate_server_credentials, [:pointer], :int
  tls_function :psk_set_client_credentials, [:pointer, :string, Datum, :psk_key_type ], :int
  tls_function :psk_set_server_credentials_function, [:pointer, :psk_creds_function], :int

  tls_function :transport_set_push_function, [:pointer, :push_function], :void
  tls_function :transport_set_pull_function, [:pointer, :pull_function], :void
  tls_function :handshake, [:pointer], :int
  tls_function :record_recv, [:pointer, :pointer, :size_t], :int
  tls_function :record_send, [:pointer, :pointer, :size_t], :int
  # tls_function :handshake_set_timeout, [:pointer, :int], :void

  tls_function :global_set_log_level, [:int], :void
  tls_function :global_set_log_function, [:log_function], :void
  tls_function :strerror, [:int], :string

  SERVER = 1
  CLIENT = 2

  class Error < RuntimeError
    def initialize message, code=nil
      message << ": #{GnuTLS.strerror(code)}" if code
      super message
    end
  end

  def self.init type
    GnuTLS.global_init unless @global_initted
    @global_initted = true

    ptr = FFI::MemoryPointer.new :pointer
    gnutls_init(ptr, type)
    ptr.read_pointer
  end

  def self.enable_logging
    @logging_function = Proc.new { |lvl,msg| puts "#{lvl} #{msg}" }
    GnuTLS.global_set_log_function @logging_function
    GnuTLS.global_set_log_level 9
  end

  class Session
    def initialize ptr, direction
      @session = ptr
      @direction = direction
      # FIXME this isn't quite the right priority string
      self.priority = "SECURE128:-VERS-SSL3.0:-VERS-TLS1.0:-ARCFOUR-128:+PSK:+DHE-PSK"
      # FIXME create ephemeral DH parameters and force DHE mode
      @buffer = String.new
    end

    def handshake
      loop do
        res = GnuTLS.handshake(@session)
        return if res == 0

        if GnuTLS.error_is_fatal(res)
          raise Error.new("failed handshake", res) unless res.zero?
        else
          warn "handshake problem (status #{res})" unless res.zero?
        end
      end
    end

    def handshake_timeout=(ms)
      GnuTLS.handshake_set_timeout(@session, ms)
    end

    def priority=(priority_str)
      GnuTLS.priority_set_direct(@session, priority_str, nil)
    end

    def socket= socket
      @socket = socket

      @pull_function = Proc.new { |_, data, maxlen|
        d = nil
        begin
          d = @socket.readpartial maxlen
        rescue EOFError
          d = ""
        end
        data.write_bytes d

        d.size
      }

      @push_function = Proc.new { |_, data, len|
        str = data.read_bytes len
        @socket.write str

        str.size
      }

      GnuTLS.transport_set_pull_function @session, @pull_function

      GnuTLS.transport_set_push_function @session, @push_function

      handshake
    end

    def psk= val
      creds = FFI::MemoryPointer.new :pointer

      allocator = "psk_allocate_#{@direction}_credentials"

      res = GnuTLS.send allocator, creds
      raise "Cannot allocate credentials" unless res == 0

      creds = creds.read_pointer

      if @direction == :client
        psk = Datum.new
        psk[:data] = FFI::MemoryPointer.from_string(val)
        psk[:size] = val.size

        setter = "psk_set_#{@direction}_credentials"

        res = GnuTLS.send setter, creds, "Bogus", psk, :PSK_KEY_RAW
        raise "Can't #{setter}" unless res == 0
      else
        @server_creds_function = Proc.new { |_,username,key_pointer|
          # ignore username

          psk = Datum.new key_pointer
          psk[:data] = FFI::MemoryPointer.from_string(val)
          psk[:size] = val.size

          0
        }

        GnuTLS.psk_set_server_credentials_function creds, @server_creds_function
      end

      res = GnuTLS.credentials_set @session, :CRD_PSK, creds
      raise "Can't credentials_set with PSK" unless res == 0

      val
    end

    def write str
      total = 0
      pointer = FFI::MemoryPointer.from_string str
      while total < str.size
        sent = GnuTLS.record_send @session, pointer + total, str.size - total
        if sent == 0
          # FIXME What does this mean?
          raise "Sent returned zero"
        elsif sent < 0
          raise GnuTLS::Error.new( "cannot send", sent )
        end
        total += sent
      end
    end

    def puts str
      write str
      write "\n"
    end

    def read len
      str = String.new
      while str.size < len
        str << readpartial( len - str.size )
      end
      str
    end

    def gets
      loop do
        if index = @buffer.index("\n")
          slice = @buffer[0..index]
          @buffer = @buffer[(index+1)..-1]
          return slice
        end

        @buffer << unbuffered_readpartial(1024 * 16)
      end
    end

    def unbuffered_readpartial len
      str = String.new << ("\0" * len)
      res = GnuTLS.record_recv @session, str, len
      if res == -9
        # A TLS packet with unexpected length was received.
        # This almost certainly means that the connection was closed.
        raise EOFError.new
      elsif res < 0
        raise Error.new("can't readpartial", res) unless res.zero?
      elsif res == 0
        raise "recv got zero"
      end

      str[0...res]
    end

    def readpartial len
      # To keep things simple, always drain the buffer first
      if @buffer.size > 0
        amount = [len,@buffer.size].min
        slice = @buffer[0...amount]
        @buffer = @buffer[amount..-1]
        return slice
      end

      unbuffered_readpartial len
    end

    def deinit
      # FIXME How do we ensure this is called?
      GnuTLS.deinit(@session)
    end
  end

  class Socket < Session
    def initialize socket, psk
      ptr = GnuTLS.init CLIENT
      super ptr, :client
      self.psk = psk
      self.socket = socket
    end
  end

  class Server < Session
    def initialize socket, psk
      ptr = GnuTLS.init SERVER
      super ptr, :server
      self.psk = psk
      self.socket = socket
    end
  end
end
