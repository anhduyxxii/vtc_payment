# based on the document http://sandbox3.vtcebank.vn/Documents/%5BTELCO%5DTai_lieu_API_su_dung_the_TELCO.pdf 07/2011 version
require "uri"
require "net/http"
require "rexml/document"
require "json"
require "logger"
module VtcPayment
  module MobileCard
    class Client
      attr_accessor :sandbox
      def initialize( partner_id, secret_key )
        @partner_id = partner_id
        @secret_key = secret_key
      end

      SANDBOX_URL = 'http://sandbox2.vtcebank.vn/WSCard2010/card.asmx?wsdl'
      PRODUCTION_URL = "" # ??

      def url
        sandbox? ? SANDBOX_URL : (raise "production url is not yet given from vtc")# PRODUCTION_URL
      end

      def sandbox?
        !! @sandbox
      end

      # cardid: serial no (Seri)
      # carccode: the number hidden under silver coating
      # des: TelcoCode | TransactionID | AccountName
      #  * TelcoCode: one of VMS/VTEL/GPC/SFONE/VNM
      #  * TransactionID: unique id generated by us to identify transaction
      #  * AccountName: name of user (who use mobile card) so that VTC can contact with him/her
      def execute( cardid, cardcode, des)
        http_response = send_request(cardid, cardcode, des)
        response = Response.build( http_response, @secret_key )
        response.code
        response
      end

      private
      def send_request( cardid, cardcode, des)
        cardfun = <<-EOS
        <?xml version="1.0" encoding="utf-16"?>
        <CardRequest>
          <Function>UseCard</Function>
          <CardID>#{cardid}</CardID>
          <CardCode>#{cardcode}</CardCode>
          <Description>#{des}</Description>
        </CardRequest>
        EOS
        request_data = Crypt.encrypt( cardfun, @secret_key )

        xml_data = <<-EOS
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
          <soap:Body>
            <Request xmlns="VTCOnline.Card.WebAPI">
              <PartnerID>#{@partner_id}</PartnerID>
              <RequestData>#{request_data}</RequestData>
            </Request>
          </soap:Body>
        </soap:Envelope>
        EOS
        # if there are unnecessary spaces VTC will reject you
        xml_data = xml_data.gsub(/\>\s+\</, "><").strip

        uri = URI.parse(url)
        headers = {
          "Host" => "#{uri.host}",
          "Content-Type" => "text/xml; charset=utf-8",
          "SOAPAction" => "VTCOnline.Card.WebAPI/Request",
          "Content-Length" => "#{xml_data.length}"
        }


        # client = HTTPClient.new
        http_res = nil
        begin
          log [ :request, uri.to_s, headers, cardfun, xml_data ].to_json
          #http_res = client.post(uri.to_s, header: headers.to_a, data: xml_data )
          # http_res = client.post_content(uri.to_s, xml_data, headers )
          http_res = post( uri.to_s, headers, xml_data )
        rescue => ex
          log [ :exception, ex.to_s, ex.message ].to_json
          # TODO: send email
          return nil # we need to return nil because we have to process next card 
        ensure
          if http_res && http_res.respond_to?(:body)
            log [ :response, http_res.body, http_res.code ].to_json rescue nil
          else
            log [ :response, http_res.inspect ].to_json rescue nil
          end
        end
        return http_res
      end

      def post( uri, headers, xml_data )
        uri = URI.parse(uri)
        https = Net::HTTP.new(uri.host, uri.port)
        # https.set_debug_output $stderr

        https.use_ssl = true if uri.scheme == "https"

        req = Net::HTTP::Post.new(uri.request_uri)

        headers.each do |k,v|
          req[k.to_s] = v.to_s
        end

        req.body = xml_data
        res = https.request(req)
      end

      def log( str )
        if defined?(Rails)
          @logger ||= Logger.new("#{Rails.root}/logs/vtc_mobile.log")
        else
          @logger ||= Logger.new("vtc_mobile.log")
        end
        @logger.info str.to_s
      end

      class FailedByException
        def successful?; false; end
        def http_status; "500"; end
        def code; "-99999"; end
        def message; "failed by exception during http connection"; end
      end

      class Response
        def self.build( http_response, secret_key )
          if http_response
            Response.new(http_response, secret_key)
          else
            FailedByException.new
          end
        end

        attr_reader :body, :status, :telco_code, :transaction_id, :account_name, :vtc_description
        def initialize(http_response, secret_key)
          @body = http_response.body
          @status = http_response.code
          # we don't store secret_key in this model
          parse_response_body(@body, secret_key)
        end

        def successful?
          # even if card is wrong, it returns 200 status code
          # if the request format is wrong it will return 400 BadRequest
          (200..299).include?(@status.to_i) &&
            code.nil?
        end

        def http_status
          @status
        end

        def code
          RESPONSE_CODE[@raw_code] && RESPONSE_CODE[@raw_code][:code]
        end

        def message
          RESPONSE_CODE[@raw_code] && RESPONSE_CODE[@raw_code][:message]
        end

        private
        #response format from http://sandbox3.vtcebank.vn/Documents/%5BTELCO%5DTai_lieu_API_su_dung_the_TELCO.pdf
        def parse_response_body(envelop_body, secret_key)
          # First unwrap the envelope
          parse_xml(envelop_body) do |node, value|
            next unless node == "RequestResult"

            body = Crypt.decrypt(value, secret_key)

            parse_xml(body) do |node, value|
              if node == "ResponseStatus"
                @raw_code = value.to_i
              elsif node == "Descripton" # not Description LOL
                @description = value.to_s
              end
            end
          end
        end

        # scan all node recursively
        def parse_xml(body, &block)
          xml = REXML::Document.new(body.to_s)
          _parse_xml(xml, &block)
        end

        def _parse_xml(xml, &block)
          xml.elements.each do |e|
            if e.is_a?(REXML::Element)
              yield [e.name, e.text ]
            end
            _parse_xml(e, &block)
          end
        end

        # not used
        # In section 2.1 it says in the Descripton partner's detail information are stored
        # <TelcoCode>| <TransactionID:bigint>|<AccountName:string>|<VTCDescription>
        # but in 1.4.1 it says it contains an error message
        # seems 1.4.1 is right
        def parse_description( description )
          raise "do not call this methods. I am an unwanted child of VTC"
          ary = description.to_s.split("|")
          if ary.size == 4
            return ary
          else
            return []
          end
        end

        RESPONSE_CODE = {
          -1 => { code: :error_used, message: "The card is used."},
          -2 => { code: :error_blocked, message: "The card is blocked."},
          -3 => { code: :error_expired, message: "The card is expired."},
          -4 => { code: :error_inactive, message: "The card is inactive."},
          -5 => { code: :error_invalid_trans_id, message: "TransID is invalid."},
          -6 => { code: :error_unmatch, message: "Card code and serial isn't matched."},
          -8 => { code: :error_too_many_errors, message: "Warning about the number of error transactions of one account."},
          -9 => { code: :error_too_many_trials, message: "The number of trying is exceeded."},
          -10 => { code: :error_invalid_card_id, message: "CardID is invalid."},
          -11 => { code: :error_invalid_code, message: "CardCode is invalid."},
          -12 => { code: :error_no_such_card, message: "The card isn't existed."},
          -13 => { code: :error_wrong_description, message: "Wrong Description structure."},
          -14 => { code: :error_no_such_service_code, message: "Service code isn't existed."},
          -15 => { code: :error_lacking_customer_info, message: "Lacking customer information."},
          -16 => { code: :error_invalid_transaction_code, message: "Transaction code is invalid."},
          -90 => { code: :error_incorrect_method, message: "Incorrect method name."},
          -98 => { code: :error_system_failure_98, message: "Transaction failed because of system failure."},
          -99 => { code: :error_system_failure_99, message: "Transaction failed because of system failure."},
          -999 => { code: :error_out_of_service, message: "Telco system is suspend."},
          -100 => { code: :error_suspicious_transaction, message: "Transaction is suspected (confirm result through control channel)."},
          -9999 => { code: :error_unknown, message: "Unidentified error occured." }
        }

      end
    end
  end
end

if $0 == __FILE__
  $:.unshift File.dirname(__FILE__)
  require "crypt"
  require "date"
  client = VtcPayment::MobileCard::Client.new("920130506", "920130506!@#123")
  client.sandbox = true
  res =  client.execute("707970449377", "PM0000008573", "VTEL|2017031601|your name")
  p [ res.successful?, res.code, res.message ]
end
