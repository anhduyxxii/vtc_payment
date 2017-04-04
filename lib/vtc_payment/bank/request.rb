require "digest"
require "cgi"
require "date"
# terminology
# account: the login account used to login VTC website
# website_id: You first need to create a business account in vtc website and then register your website.
#             After the registration you visit the registraion management screen and see the id of your website. It's your website_id
# secret_key: when you register you need to decide your secret key.
# callback_url
# param_extend: see http://sandbox3.vtcebank.vn/Documents/Website_Integrated_en.pdf
#
# USAGE
# req = VtcPayment::Bank::Request.new( account, website_id, SECRET_KEY, callback_url )
# params = {
#   order_id: 1234, # required
#   amount: 100000, # VND, required
#   first_name: ,
#   last_name: ,
#   mobile: ,
#   address1: ,
#   address2: ,
#   city_name: ,
#   country: ,
#   email: ,
#   order_description: ,
# }
# url = req.url(params)
module VtcPayment
  module Bank
    class Request
      class << self
        attr_accessor :production_url # class_attribute
      end
      attr_accessor :sandbox
      def initialize( account, website_id, secret_key, callback_url )
        @account = account.to_s
        @website_id = website_id.to_s
        @secret_key = secret_key.to_s
        @callback_url = callback_url.to_s
        raise "account, website_id, secret_key, callback_url must not be blank." if [ @account, @website_id, @secret_key, @callback_url ].any?{|e| e.to_s.empty? }
      end

      def sandbox?
        # p [ @sandbox, defined?(Rails)]
        if !@sandbox.nil?
          @sandbox # true or false
        else
          (defined? (Rails) && ! Rails.env.production )
        end
      end

      def base_url
        # from pdf document
        sandbox? ? "http://sandbox1.vtcebank.vn/pay.vtc.vn/cong-thanh-toan/checkout.html" : 
          VtcPayment::Bank::Request.production_url
      end

      # If you want to limit payment type, choose sub classes defined below
      def screen_method
        "" # choose from all three methods (VTCPay, Credit, Bank)
      end

      class CreditCard < Request
        def screen_method
          "InternationalCard"
        end
        %W(Visa Master).each do |card|
          module_eval <<-EOS
            class #{card} < CreditCard
              def screen_method
                "#{card}"
              end
            end
          EOS
        end
      end

      class Bank < Request
        def screen_method
          "DomesticBank"
        end
        %W(Vietcombank Techcombank MB Vietinbank Agribank DongABank Oceanbank BIDV SHB VIB MaritimeBank Eximbank ACB HDBank NamABank SaigonBank Sacombank VietABank VPBank TienPhongBank SeaABank PGBank Navibank GPBank BACABANK PHUONGDONG  ABBANK LienVietPostBank BVB).each do |bank|
          module_eval <<-EOS
            class #{bank} < Bank
              def screen_method
                "#{bank}"
              end
            end
          EOS
        end
      end

      class VTCPay < Request
        def screen_method
          "VTCPay"
        end
      end

      module Currency
        VND = "VND"
        USD = "USD"
      end

      # notice you need to escapeHTML when you embed this link in your javascript code.
      def url( params )
        raise "amount has to be a positive number" if params[:amount].to_i <= 0
        raise "order id can not be blank" if params[:order_id].to_s.empty?

        data = [
          params[:amount].to_i.to_s,
          params[:address].to_s,
          params[:city_name].to_s,
          params[:email].to_s,
          params[:first_name].to_s,
          params[:telephone].to_s,
          params[:last_name].to_s,
          Currency::VND,
          screen_method(),
          @account,
          params[:ref_no],
          @callback_url,
          @website_id,
          @secret_key
        ].join("|")
        signature = Digest::SHA256.hexdigest( data ).upcase
        url = base_url()

        query = {
          "amount": params[:amount].to_i.to_s,
          "bill_to_address": CGI.escape(params[:address].to_s),
          "bill_to_address_city": CGI.escape(params[:city_name].to_s),
          "bill_to_email": CGI.escape(params[:email].to_s),
          "bill_to_forename": CGI.escape(params[:first_name].to_s),
          "bill_to_phone": CGI.escape(params[:telephone].to_s),
          "bill_to_surname": CGI.escape(params[:last_name].to_s),
          "currency": Currency::VND,
          "payment_type": CGI.escape(screen_method()),
          "receiver_account": @account,
          "reference_number": params[:ref_no],
          "url_return": CGI.escape(@callback_url.to_s),
          "website_id": @website_id,
          "signature": signature,
        }
        url += "?"
        url +=  query.map{|k,v| [k,v].join("=") }.join("&")
        url
      end
    end
  end
end

