"""使用 while 循环练习菜单选择、求和与连乘（面向过程写法）。"""

from decimal import Decimal, DecimalException, Inexact, localcontext


try:
    while True:
        print("\n主菜单")
        print("[a] 数据求和")
        print("[b] 计算 1～50 的和")
        print("[c] 计算 1×2×3×4×5 的值")
        print("[d] 循环5次")
        print("[q] 退出程序")
        choice = input("请选择：").strip().lower()

        if choice == "a":
            while True:
                print("\n数据求和")
                print("[1] 逐个输入数字求和")
                print("[2] 一行输入多个数字求和")
                print("[q] 返回上一级")
                sum_choice = input("请选择：").strip().lower()

                if sum_choice == "1":
                    total = Decimal(0)
                    print("\n逐个求和：输入数字后回车；输入 0 结束，输入 q 返回上一级。")

                    while True:
                        text = input("请输入数字：").strip()
                        if text.lower() == "q":
                            break

                        try:
                            number = Decimal(text)
                            if not number.is_finite():
                                print("输入无效，请输入一个有限的数字。")
                                continue
                        except (DecimalException, ValueError):
                            print("输入无效，请输入一个有限的数字。")
                            continue

                        if number.is_zero():
                            print(f"最终总和为：{total}")
                            break

                        try:
                            # 增大精度
                            with localcontext() as context:
                                context.prec = 10000
                                context.traps[Inexact] = True
                                total += number
                        except DecimalException:
                            print("数字过大或位数过多，无法精确求和，请输入较小的数字。")
                            continue
                        print(f"当前总和为：{total}")

                elif sum_choice == "2":
                    print("\n批量求和：用空格隔开多个数字，回车求和；输入 q 返回上一级。")

                    while True:
                        text = input("请输入数字：").strip()
                        if text.lower() == "q":
                            break
                        if not text:
                            print("输入不能为空，请输入至少一个数字。")
                            continue

                        numbers = []
                        valid = True
                        for token in text.split():
                            try:
                                number = Decimal(token)
                                if not number.is_finite():
                                    valid = False
                                    print(f"输入无效：{token!r} 不是有限的数字，请重新输入整行。")
                                    break
                                numbers.append(number)
                            except (DecimalException, ValueError):
                                valid = False
                                print(f"输入无效：{token!r} 不是有限的数字，请重新输入整行。")
                                break

                        if not valid:
                            continue

                        try:
                            total = Decimal(0)
                            with localcontext() as context:
                                context.prec = 10000
                                context.traps[Inexact] = True
                                for number in numbers:
                                    total += number
                        except DecimalException:
                            print("数字过大或位数过多，无法精确求和，请输入较小的数字。")
                            continue
                        print(f"总和为：{total}")

                elif sum_choice == "q":
                    break
                else:
                    print("无效选择，请输入 1、2 或 q。")

        elif choice == "b":
            number = 1
            total = 0
            while number <= 50:
                total += number
                number += 1
            print(f"1～50 的和为：{total}")

        elif choice == "c":
            number = 1
            product = 1
            while number <= 5:
                product *= number
                number += 1
            print(f"1×2×3×4×5 的值为：{product}")

        elif choice == "d":
            a=0
            for _ in range(5):
                a+=1
                print(f"第{a}次")


        elif choice == "q":
            print("程序已退出。")
            break
        else:
            print("无效选择，请输入 a、b、c 或 q。")

except (KeyboardInterrupt, EOFError):
    print("\n输入已结束，程序退出。")
