def add_item(items, value):
    items.append(value)


numbers = [10, 20]
alias = numbers
add_item(alias, 30)

# is 检查两个名字是否指向同一个对象。
print(alias is numbers)
print(numbers)
