price = 20
count = 3
total = price * count
if total >= 50:
    discount = 10
else:
    discount = 0
payment = total - discount
print(payment)
