# 🌊AquaNvim

![AquaNvim](https://i.ibb.co/cKW6QWrb/2025-06-06-170250-hyprshot.png)

## Install 

### ❓Make a backup of your current nvim config (if exists)

``` mv ~/.config/nvim ~/.config/nvim.bak ```

### ❓Clean neovim folders (Optional but recommended)

```
mv ~/.local/share/nvim ~/.local/share/nvim.bak
mv ~/.local/state/nvim ~/.local/state/nvim.bak
mv ~/.cache/nvim ~/.cache/nvim.bak
```

### ✅Clone the repository

```
git clone --depth 1 https://github.com/posedonYT/AquaNvim.git ~/.config/nvim
rm -rf ~/.config/nvim/.git
nvim
```

## 🆒Hotkeys

``` Space + e ``` -> Open File Explorer

``` y ``` -> Copy Selection

``` yy ``` -> Copy Line

``` p ``` -> Paste

``` Shift + v ``` -> Visual Line Mode

``` Ctrl + a ``` -> Select All

✅ If you have selected a section of code, you can comment out the line by pressing ``` / ``` as it is implemented in the IDE.

## Config 

➕ Automatically config stores LSPs for programming languages such as: Lua, C, C++, Python, JavaScript, TypeScript, Rust.

❗ You can edit the languages used in the file ``` /lua/plugins/lsp.lua ```

