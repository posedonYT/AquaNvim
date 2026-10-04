# Изолированное окружение: не трогает ~/.config/nvim и ~/.local/share/nvim
TESTS   := $(CURDIR)/.tests
ENV     := XDG_CONFIG_HOME=$(TESTS)/config XDG_DATA_HOME=$(TESTS)/data \
           XDG_STATE_HOME=$(TESTS)/state XDG_CACHE_HOME=$(TESTS)/cache NVIM_APPNAME=aquanvim
NVIM    ?= nvim

.PHONY: test sync run clean

$(TESTS)/config/aquanvim:
	@mkdir -p $(TESTS)/config
	@ln -sfn $(CURDIR) $(TESTS)/config/aquanvim

sync: $(TESTS)/config/aquanvim
	@$(ENV) AQUA_TEST=1 $(NVIM) --headless "+Lazy! sync" +qa

test: $(TESTS)/config/aquanvim
	@$(ENV) AQUA_TEST=1 $(NVIM) --headless "+Lazy! install" +qa
	@$(ENV) AQUA_TEST=1 $(NVIM) --headless -c "luafile tests/run.lua"

# Запустить AquaNvim в изолированном окружении (рядом с основным конфигом)
run: $(TESTS)/config/aquanvim
	@$(ENV) $(NVIM)

clean:
	rm -rf $(TESTS)
