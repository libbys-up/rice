
f True = False
f x = not (let y = not x in not y)

main = f True
