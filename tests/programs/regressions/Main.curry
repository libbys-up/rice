-- A program whose root module is Main. Rice wrote its C driver to main.c
-- in the same directory as the module's Main.c, and on a case-insensitive
-- file system (macOS's default) the driver replaced the module: the link
-- failed with Main__main_hnf undefined. Found compiling Rice.Main.
main :: Int
main = 42
