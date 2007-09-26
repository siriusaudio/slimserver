var MainMenu = function(){
	var url = new Array();

	return {
		init : function(){
			Ext.EventManager.onWindowResize(this.onResize, this);
			Ext.EventManager.onDocumentReady(this.onResize, this, true);

			// use "display:none" to hide inactive elements
			var items = Ext.DomQuery.select('div.homeMenuSection, span.overlappingCrumblist, div#livesearch, div.expandableHomeMenuItem');
			for(var i = 0; i < items.length; i++) {
				if (el = Ext.get(items[i].id)) {
					el.setVisibilityMode(Ext.Element.DISPLAY);
					if (el.hasClass('expandableHomeMenuItem'))
						el.setVisible(false);
				}
			}

			Utils.initSearch();

			var anchor = document.location.href.match(/#(.*)\?/)
			if (!(anchor && anchor[1] && this.showPanel(anchor[1].toLowerCase()))) {
				this.showPanel('home');
			}
		},

		addUrl : function(key, value){
			url[key] = value;
		},

		doMenu : function(item){
			switch (item) {
				case 'MY_MUSIC':
					this.showPanel('my_music');
					break;

				case 'RADIO':
					this.showPanel('radio');
					break;

				case 'MUSIC_ON_DEMAND':
					this.showPanel('music_on_demand');
					break;

				case 'PLUGINS':
					this.showPanel('plugins');
					break;

				default:
					if (url[item]) {
						var cat = item.match(/:(.*)$/);
						location.href = url[item] + (cat && cat.length >= 2 && cat[1] != 'browse' ? '&homeCategory=' + cat[1] : '');
					}
					break;
			}
		},

		toggleItem : function(panel){
			var el = Ext.get(panel);
			if (el) {
				if (el.hasClass('homeMenuItem_expanded'))
					this.collapseItem(panel, true);
				else
					this.expandItem(panel);
			}
		},

		expandItem : function(panel){
			// we only allow for one open item
			this.collapseAll();

			Utils.setCookie('SlimServer-homeMenuExpanded', panel);

			var el = Ext.get(panel);
			if (el) {
				var icon = el.child('img:first', true);
				if (icon)
					Ext.get(icon).addClass('disclosure_expanded');

				el.addClass('homeMenuItem_expanded');

				var subPanel = Ext.get(panel + '_expanded');
				if (subPanel) {
					subPanel.setVisible(true);
					subPanel.addClass('homeMenuSection_expanded');
				}

			}

			this.onResize();
		},

		collapseItem : function(panel, resetState){
			if (resetState)
				Utils.setCookie('SlimServer-homeMenuExpanded', '');

			var el = Ext.get(panel);
			if (el) {
				if (icon = el.child('img:first', true))
					Ext.get(icon).removeClass('disclosure_expanded');

				el.removeClass('homeMenuItem_expanded');

				var subPanel = Ext.get(panel + '_expanded');
				if (subPanel){
					subPanel.setVisible(false);
					subPanel.removeClass('homeMenuSection_expanded');
				}
			}

			Utils.resizeContent();
			this.onResize();
		},

		collapseAll : function(){
			var items = Ext.DomQuery.select('div.homeMenuItem_expanded');
			for(var i = 0; i < items.length; i++) {
				this.collapseItem(items[i].id);
			}
		},

		showPanel : function(panel){
			var panelExists = false;
			this.collapseAll();

			// make plugins show up in the "Extras" panel
			if (panel == 'plugins')
				panel = 'plugins';

			var items = Ext.DomQuery.select('div.homeMenuSection');
			for(var i = 0; i < items.length; i++) {
				if (el = Ext.get(items[i].id)) {
					el.setVisible(panel + 'Menu' == items[i].id);
					panelExists |= (panel + 'Menu' == items[i].id);
				}
			}

			items = Ext.DomQuery.select('span.overlappingCrumblist');
			for(var i = 0; i < items.length; i++) {
				if (el = Ext.get(items[i].id))
					el.setVisible(panel + 'Crumblist' == items[i].id);
			}

			Ext.get('pagetitle').update(strings[panel] ? strings[panel] : strings['home']);

			if (panel == 'my_music' || panel == 'search')
				Ext.get('livesearch').setVisible(true);
			else
				Ext.get('livesearch').setVisible(false);

			if (panel == 'home') {
				this.expandItem(Utils.getCookie('SlimServer-homeMenuExpanded'));
				Ext.get('titleBottom').replaceClass('titlebox_bottom_crumb', 'titlebox_bottom');
				Ext.get('crumblist').removeClass('crumblist');
			}
			else {
				Ext.get('titleBottom').replaceClass('titlebox_bottom', 'titlebox_bottom_crumb');
				Ext.get('crumblist').addClass('crumblist');
			}

			this.onResize();

			return panelExists;
		},

		onResize : function(){
			var contW = Ext.get(document.body).getWidth() - 30
			Ext.select('div.homeMenuSection').setWidth(contW);

			var el;
			if (Ext.isIE && !Ext.isIE7 && (el = Ext.DomQuery.selectNode('div.inner_content')))
				Ext.get(el).setWidth(contW+25);

		}
	}
}();