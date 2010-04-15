module Typus

  module Authentication

    module Advanced

      protected

      # Require login checks if the user is logged on Typus, otherwise 
      # is sent to the sign in page with a :back_to param to return where 
      # she tried to go.
      def authenticate

        # Uncomment the following line for demo purpouses.
        # session[:typus_user_id] = Typus.user_class.first

        if session[:typus_user_id]
          current_user
        else
          back_to = request.env['PATH_INFO'] unless [admin_dashboard_path, admin_path].include?(request.env['PATH_INFO'])
          redirect_to new_admin_session_path(:back_to => back_to)
        end

      end

      # Return the current user. If role does not longer exist on the 
      # system @current_user will be signed out from Typus.
      def current_user

        @current_user = Typus.user_class.find(session[:typus_user_id])

        unless Typus::Configuration.roles.has_key?(@current_user.role)
          raise _("Role does no longer exists.")
        end

        unless @current_user.status
          back_to = (request.env['REQUEST_URI'] == admin_dashboard_path) ? nil : request.env['REQUEST_URI']
          raise _("Typus user has been disabled.")
        end

        I18n.locale = @current_user.preferences[:locale]

      rescue Exception => error
        flash[:notice] = error.message
        session[:typus_user_id] = nil
        redirect_to new_admin_session_path(:back_to => back_to)
      end

      # Action is available on: edit, update, toggle and destroy
      def check_if_user_can_perform_action_on_user

        return unless @item.kind_of?(Typus.user_class)

        current_user = (@current_user == @item)

        message = case params[:action]
                  when 'edit'

                    # Only admin and owner of Typus User can edit.
                    if @current_user.is_not_root? && !current_user
                      _("As you're not the admin or the owner of this record you cannot edit it.")
                    end

                  when 'update'

                    # current_user cannot change her role.
                    if current_user && !(@item.role == params[@object_name][:role])
                      _("You can't change your role.")
                    end

                  when 'toggle'

                    # Only admin can toggle typus user status, but not herself.
                    if @current_user.is_root? && current_user
                      _("You can't toggle your status.")
                    elsif @current_user.is_not_root?
                      _("You're not allowed to toggle status.")
                    end

                  when 'destroy'

                    # Admin can remove anything except herself.
                    if @current_user.is_root? && current_user
                      _("You can't remove yourself.")
                    elsif @current_user.is_not_root?
                      _("You're not allowed to remove Typus Users.")
                    end

                  end

        if message
          flash[:notice] = message
          redirect_to request.referer || admin_dashboard_path
        end

      end

      # This method checks if the user can perform the requested action.
      # It works on models, so its available on the admin_controller.
      def check_if_user_can_perform_action_on_resources

        message = case params[:action]
                  when 'index', 'show'
                    "{{current_user_role}} can't display items."
                  when 'destroy'
                    "{{current_user_role}} can't delete this item."
                  else
                    "{{current_user_role}} can't perform action. ({{action}})"
                  end

        message = _(message, 
                    :current_user_role => @current_user.role.capitalize, 
                    :action => params[:action])

        unless @current_user.can?(params[:action], @resource[:class])
          flash[:notice] = message
          redirect_to request.referer || admin_dashboard_path
        end

      end

      # This method checks if the user can perform the requested action.
      # It works on a resource: git, memcached, syslog ...
      def check_if_user_can_perform_action_on_resource
        controller = params[:controller].extract_resource
        action = params[:action]
        unless @current_user.can?(action, controller.camelize, { :special => true })
          flash[:notice] = _("{{current_user_role}} can't go to {{action}} on {{controller}}.", 
                             :current_user_role => @current_user.role.capitalize, 
                             :action => action, 
                             :controller => controller.humanize.downcase)
          redirect_to request.referer || admin_dashboard_path
        end
      end

      ##
      # If item is owned by another user, we only can perform a 
      # show action on the item. Updated item is also blocked.
      #
      #   before_filter :check_resource_ownership, :only => [ :edit, :update, :destroy, 
      #                                                       :toggle, :position, 
      #                                                       :relate, :unrelate ]
      #
      def check_resource_ownership

        # By-pass if current_user is root.
        return if @current_user.is_root?

        condition_typus_users = @item.respond_to?(Typus.relationship) && !@item.send(Typus.relationship).include?(@current_user)
        condition_typus_user_id = @item.respond_to?(Typus.user_fk) && !@item.owned_by?(@current_user)

        if condition_typus_users || condition_typus_user_id
           path = request.referer || admin_dashboard_path
           alert = _("You don't have permission to access this item.")

           redirect_to path, :alert => alert
        end

      end

      def check_resource_ownerships

        # By-pass if current_user is root.
        return if @current_user.is_root?

        # Show only related items it @resource has a foreign_key (Typus.user_fk) 
        # related to the logged user.
        if @resource[:class].typus_user_id?
          condition = { Typus.user_fk => @current_user }
          @conditions = @resource[:class].merge_conditions(@conditions, condition)
        end

      end

      def check_ownership_of_referal_item
        return unless params[:resource] && params[:resource_id]
        klass = params[:resource].classify.constantize
        return if !klass.typus_user_id?
        item = klass.find(params[:resource_id])
        raise "You're not owner of this record." unless item.owned_by?(@current_user) || @current_user.is_root?
      end

      # If we want to display only user items, we don't want the links previous and 
      # next linking to records from other users.
      def set_conditions
        condition = @current_user.is_root? || 
                    !@resource[:class].typus_options_for(:only_user_items) || 
                    !@resource[:class].columns.map(&:name).include?(Typus.user_fk)
        !condition ? { Typus.user_fk => @current_user.id } : {}
      end

      def set_attributes_on_create
        if @resource[:class].typus_user_id?
          @item.attributes = { Typus.user_fk => @current_user.id }
        end
      end

      def set_attributes_on_update
        if @resource[:class].typus_user_id? && @current_user.is_not_root?
          @item.update_attributes(Typus.user_fk => @current_user.id)
        end
      end

      # Reload @current_user when updating to see flash message in the 
      # correct locale.
      def reload_locales
        if @resource[:class].eql?(Typus.user_class)
          I18n.locale = @current_user.reload.preferences[:locale]
          @resource[:human_name] = params[:controller].extract_human_name
        end
      end

    end

  end

end