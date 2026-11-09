app [main!] { pf: platform "main.roc" }
import pf.Host exposing [echo!]
main! = |argument| echo!(argument.to_str())
