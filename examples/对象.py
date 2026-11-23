class Student:
    def __init__(self, name):
        self.name = name
        self.scores = []

    def add_score(self, score):
        self.scores.append(score)
        return sum(self.scores)


student = Student('小林')
friend = student
total = friend.add_score(90)
print(student.scores)
print(student.name, total)
